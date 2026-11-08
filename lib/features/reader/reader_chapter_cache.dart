import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/chapter_content.dart';
import '../../data/models/json_utils.dart';

/// 本地缓存命中结果。
@immutable
class ReaderChapterHit {
  const ReaderChapterHit({required this.content, required this.isStale});

  final ChapterContent content;

  /// 抓取时间超过 [ReaderChapterCache.staleAfter] 的旧条目仍可先展示，
  /// 调用方可在后台刷新一次缓存，不阻塞当前阅读。
  final bool isStale;
}

/// 章节正文本地缓存。
///
/// 每次切章都请求上游又慢又费流量，所以正文落盘复用。目录动辄上千章，
/// 全存会把 App 撑大：最多保留 [maxFiles] 个文件，超出按 mtime 淘汰最旧的；
/// 内存再叠一层 [memoryCapacity] 章 LRU，避免同一次阅读反复读盘解 JSON。
///
/// 缓存是"加速层"不是"数据源"：任何 IO/解析异常都降级为 miss，正文仍会
/// 照常请求，所以这里所有失败都静默处理。
class ReaderChapterCache {
  ReaderChapterCache({
    Future<Directory> Function()? supportDirectory,
    this.memoryCapacity = 8,
    this.maxFiles = 300,
    this.staleAfter = const Duration(days: 7),
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _dirName = 'reader_chapters';

  final Future<Directory> Function() _supportDirectory;
  final int memoryCapacity;
  final int maxFiles;
  final Duration staleAfter;

  Future<Directory>? _dirFuture;

  /// 键是 chapterId。每次命中先 remove 再 put，Map 的插入顺序即 LRU 顺序。
  final Map<String, ReaderChapterHit> _memory = <String, ReaderChapterHit>{};

  /// 读缓存：内存 → 磁盘。返回 null 表示 miss。
  Future<ReaderChapterHit?> get(String chapterId) async {
    if (chapterId.isEmpty) return null;

    final cached = _memory.remove(chapterId);
    if (cached != null) {
      _memory[chapterId] = cached;
      return cached;
    }

    try {
      final directory = await _directory();
      final file = File('${directory.path}/${_fileName(chapterId)}');
      if (!await file.exists()) return null;
      final hit = _decode(await file.readAsString(), chapterId);
      if (hit == null) {
        // 损坏/半截文件直接删掉，避免每次进来都白读一遍。
        await _deleteQuietly(file);
        return null;
      }
      _remember(chapterId, hit);
      return hit;
    } catch (_) {
      // 磁盘不可用（权限/沙盒/测试环境）等同于 miss。
      return null;
    }
  }

  /// 写缓存：先写内存（当前进程立即命中），再临时文件 + rename 原子落盘。
  Future<void> put(ChapterContent content) async {
    if (content.id.isEmpty) return;
    final fetchedAt = DateTime.now();
    _remember(content.id, ReaderChapterHit(content: content, isStale: false));
    try {
      final directory = await _directory();
      final target = File('${directory.path}/${_fileName(content.id)}');
      final temp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temp.writeAsString(
        jsonEncode(_encode(content, fetchedAt)),
        flush: true,
      );
      // rename 在同目录内是原子的：即便写一半进程被杀，也不会留下坏正文。
      await temp.rename(target.path);
      await _trim(directory);
    } catch (_) {
      // 写失败只影响下次是否命中，不影响本次阅读。
      return;
    }
  }

  Map<String, dynamic> _encode(ChapterContent content, DateTime fetchedAt) => {
    'id': content.id,
    'title': content.title,
    'paragraphs': content.paragraphs,
    // 段评锚点：与 paragraphs 等长；老缓存没有这个字段，读出来当无锚点。
    if (content.paraIndices.isNotEmpty) 'paraIndices': content.paraIndices,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
  };

  /// 段落 id 必须与段落数严格对齐：长度对不上（老缓存/坏文件）就当没有锚点，
  /// 宁可少画气泡也不能把段评挂到别的段上。
  List<int?> _decodeParaIndices(Object? raw, int length) {
    if (raw is! List || raw.length != length) return const <int?>[];
    final out = <int?>[];
    for (final item in raw) {
      if (item == null) {
        out.add(null);
      } else if (item is int) {
        out.add(item);
      } else if (item is String) {
        out.add(int.tryParse(item));
      } else {
        return const <int?>[];
      }
    }
    return List<int?>.unmodifiable(out);
  }

  ReaderChapterHit? _decode(String raw, String chapterId) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      final rawParagraphs = json['paragraphs'];
      if (rawParagraphs is! List) return null;
      final paragraphs = <String>[];
      for (final item in rawParagraphs) {
        if (item is! String) return null;
        if (item.trim().isEmpty) continue;
        paragraphs.add(item);
      }
      if (paragraphs.isEmpty) return null;

      final fetchedAt = asInt(json['fetchedAt']);
      final fetchedTime = DateTime.fromMillisecondsSinceEpoch(
        fetchedAt > 0 ? fetchedAt : 0,
      );
      final storedId = asString(json['id']);
      return ReaderChapterHit(
        content: ChapterContent(
          id: storedId.isEmpty ? chapterId : storedId,
          title: asString(json['title']),
          paragraphs: List<String>.unmodifiable(paragraphs),
          paraIndices: _decodeParaIndices(
            json['paraIndices'],
            paragraphs.length,
          ),
        ),
        // 没有抓取时间的老文件一律当作过期，下次后台刷新补上。
        isStale:
            fetchedAt <= 0 ||
            DateTime.now().difference(fetchedTime) > staleAfter,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _directory() async {
    final cached = _dirFuture;
    if (cached != null) return cached;
    final future = _resolveDirectory();
    _dirFuture = future;
    try {
      return await future;
    } catch (_) {
      // 失败的路径不缓存，下次再试。
      _dirFuture = null;
      rethrow;
    }
  }

  Future<Directory> _resolveDirectory() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/$_dirName');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  void _remember(String chapterId, ReaderChapterHit hit) {
    _memory.remove(chapterId);
    _memory[chapterId] = hit;
    while (_memory.length > memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// 超过 [maxFiles] 时按文件 mtime 从旧到新淘汰。目录列表最多几百个文件，
  /// 只在写入后跑一次，成本可以接受。
  Future<void> _trim(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) files.add(entity);
    }
    if (files.length <= maxFiles) return;

    final byAge = <(File, DateTime)>[];
    for (final file in files) {
      try {
        byAge.add((file, (await file.stat()).modified));
      } catch (_) {
        // 统计失败的文件跳过，不为清理打断本次写入。
      }
    }
    byAge.sort((a, b) => a.$2.compareTo(b.$2));
    final removeCount = files.length - maxFiles;
    for (var i = 0; i < removeCount && i < byAge.length; i++) {
      await _deleteQuietly(byAge[i].$1);
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      return;
    }
  }

  /// chapterId 原样做文件名可能含路径分隔符/非法字符，用 Base64URL 确定性编码。
  String _fileName(String chapterId) =>
      '${base64Url.encode(utf8.encode(chapterId)).replaceAll('=', '')}.json';
}

/// 进程级缓存：内存 LRU 跨阅读页复用，退出阅读页不清空。
final readerChapterCacheProvider = Provider<ReaderChapterCache>(
  (ref) => ReaderChapterCache(),
);
