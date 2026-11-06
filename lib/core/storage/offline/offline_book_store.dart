import 'dart:convert';
import 'dart:io';

import '../../../data/models/chapter.dart';
import '../../../data/models/chapter_content.dart';
import '../../../data/models/json_utils.dart';
import 'offline_book.dart';
import 'offline_paths.dart';

/// 小说离线区：manifest + 每章正文 JSON。
///
/// 目录与自动加速层（`reader_chapters/`）完全隔离：这里的内容**只**由用户
/// 显式删除，不参与任何自动淘汰，见 docs/offline-cache.md §3 的不变式。
///
/// 所有读方法遇到 IO/解析异常都降级为 miss（自愈：坏章节文件删除），绝不
/// 把半截数据当正文交给阅读页；写方法失败向上抛，由下载器暂停任务并提示。
class OfflineBookStore {
  OfflineBookStore({OfflinePaths? paths}) : _paths = paths ?? OfflinePaths();

  /// 小说离线区软上限（1 GiB）：超限阻止新任务并引导清理。
  static const int novelCapBytes = 1024 * 1024 * 1024;

  static const String manifestName = 'book.json';

  final OfflinePaths _paths;

  /// 读 manifest；没有/schema 不匹配/损坏都返回 null。
  Future<OfflineBook?> read(String bookId) async {
    if (bookId.isEmpty) return null;
    try {
      final file = File('${(await _paths.bookDir(bookId)).path}/$manifestName');
      if (!await file.exists()) return null;
      return OfflineBook.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// 开始一个整本任务：写完整 manifest（章节列表 + 元信息）。
  Future<void> begin(OfflineBook book) async {
    final directory = await ensureDirectory(await _paths.bookDir(book.bookId));
    await writeJsonAtomically(
      File('${directory.path}/$manifestName'),
      book.toJson(),
    );
  }

  /// 进度防抖落盘（暂停 / 完成 / 取消 / 每 30s 调用一次）。
  Future<void> saveManifest(OfflineBook book) => begin(book);

  /// 章节文件路径（`<chapterKey>.json`）。
  Future<File> chapterFile(String bookId, String chapterId) async => File(
    '${(await _paths.bookDir(bookId)).path}/${encodeOfflineKey(chapterId)}.json',
  );

  /// 按"文件是否存在"找缺口（断点续传的唯一依据）。
  ///
  /// 不依赖 manifest 的 completed 字段：进程被杀时它可能偏小/偏大。
  Future<List<String>> missingChapterIds(
    String bookId,
    List<Chapter> chapters,
  ) async {
    final missing = <String>[];
    for (final chapter in chapters) {
      if (chapter.id.isEmpty) continue;
      final file = await chapterFile(bookId, chapter.id);
      if (!await file.exists()) missing.add(chapter.id);
    }
    return missing;
  }

  /// 读一章离线正文；损坏/半截文件删除并当 miss。
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async {
    if (chapterId.isEmpty) return null;
    try {
      final file = await chapterFile(bookId, chapterId);
      if (!await file.exists()) return null;
      final content = _decodeChapter(
        jsonDecode(await file.readAsString()),
        chapterId,
      );
      if (content == null) {
        // 坏文件不留在盘上，避免每次进来都白读一次。
        await deleteQuietly(file);
        return null;
      }
      return content;
    } catch (_) {
      // 半截/不可读文件同样自愈删除（下次下载器会按缺口补回）。
      try {
        await deleteQuietly(await chapterFile(bookId, chapterId));
      } catch (_) {
        // 路径都算不出来时只能放弃。
      }
      return null;
    }
  }

  /// 写一章正文（与 `ReaderChapterCache` 同一 JSON 结构）。
  ///
  /// 返回写入字节数，供 manifest 的 `bytes` 进度统计（返回值比契约的
  /// `Future<void>` 多一个 int，对 `await` 调用方向后兼容）。
  Future<int> writeChapter(String bookId, ChapterContent content) async {
    if (content.id.isEmpty) return 0;
    final json = {
      'id': content.id,
      'title': content.title,
      'paragraphs': content.paragraphs,
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await writeJsonAtomically(await chapterFile(bookId, content.id), json);
    // 与落盘 JSON 实际字节数一致（含键名，略大于纯正文，够做进度展示）。
    return utf8.encode(jsonEncode(json)).length;
  }

  /// 小说列表（只读 manifest，不扫盘；没有任何 manifest 的目录会被跳过，
  /// 由 [pruneOrphans] 清理）。
  Future<List<OfflineBookSummary>> summaries() async {
    final out = <OfflineBookSummary>[];
    for (final directory in await listChildDirectories(
      await _paths.novelDir(),
    )) {
      final book = await _readFromDirectory(directory);
      if (book != null) out.add(OfflineBookSummary.fromBook(book));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 按文件存在校正 manifest 的 completed / bytes（进入管理页、恢复任务时调）。
  Future<void> reconcile(String bookId) async {
    final book = await read(bookId);
    if (book == null) return;
    final directory = await _paths.bookDir(bookId);
    var completed = 0;
    var bytes = 0;
    for (final chapter in book.chapters) {
      final file = File(
        '${directory.path}/${encodeOfflineKey(chapter.id)}.json',
      );
      try {
        if (await file.exists()) {
          completed += 1;
          bytes += await file.length();
        }
      } catch (_) {
        // 单文件 stat 失败按缺失处理。
      }
    }
    await saveManifest(
      book.copyWith(
        completed: completed,
        bytes: bytes,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// 删除一本书的离线内容（调用方负责先取消进行中的任务）。
  Future<void> delete(String bookId) async {
    if (bookId.isEmpty) return;
    await deleteDirectoryQuietly(await _paths.bookDir(bookId));
  }

  /// 清空整个小说离线区（不影响短剧区）。
  Future<void> clearAll() async {
    await deleteDirectoryQuietly(await _paths.novelDir());
  }

  /// 小说区统计：只累加 manifest 的 bytes（列表页不扫盘）。
  Future<OfflineStats> stats() async {
    var count = 0;
    var bytes = 0;
    for (final directory in await listChildDirectories(
      await _paths.novelDir(),
    )) {
      final book = await _readFromDirectory(directory);
      if (book == null) continue;
      count += 1;
      bytes += book.bytes;
    }
    return OfflineStats(count: count, bytes: bytes, capBytes: novelCapBytes);
  }

  /// 清理没有 manifest（崩溃残留/半截目录）的孤立目录，以及残留 `.part`
  /// 文件；返回删除的目录数。管理页打开时调用（此时不应有进行中的任务）。
  Future<int> pruneOrphans() async {
    var removed = 0;
    for (final directory in await listChildDirectories(
      await _paths.novelDir(),
    )) {
      final book = await _readFromDirectory(directory);
      if (book == null) {
        await deleteDirectoryQuietly(directory);
        removed += 1;
        continue;
      }
      await _deletePartFiles(directory);
    }
    return removed;
  }

  Future<OfflineBook?> _readFromDirectory(Directory directory) async {
    try {
      final file = File('${directory.path}/$manifestName');
      if (!await file.exists()) return null;
      return OfflineBook.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// 清理离线区里残留的 `.part` 文件（半截写/下载中断）。
  ///
  /// 启动恢复时调用：只删半截文件，不碰正式内容，也不删孤立目录
  /// （孤立目录由管理页的 [pruneOrphans] 处理）。
  Future<void> cleanupPartFiles() async {
    await _deletePartFiles(await _paths.novelDir(), recursive: true);
  }

  Future<void> _deletePartFiles(
    Directory directory, {
    bool recursive = false,
  }) async {
    try {
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('.part')) {
          await deleteQuietly(entity);
        }
      }
    } catch (_) {
      // 清理失败留给下次。
    }
  }

  ChapterContent? _decodeChapter(Object? raw, String chapterId) {
    final json = asMap(raw);
    if (json == null) return null;
    final rawParagraphs = json['paragraphs'];
    if (rawParagraphs is! List) return null;
    final paragraphs = <String>[];
    for (final item in rawParagraphs) {
      if (item is! String) return null;
      if (item.trim().isEmpty) continue;
      paragraphs.add(item);
    }
    // 空正文不算缓存成功（下载器会回退单章重试）。
    if (paragraphs.isEmpty) return null;
    final storedId = asString(json['id']);
    return ChapterContent(
      id: storedId.isEmpty ? chapterId : storedId,
      title: asString(json['title']),
      paragraphs: List<String>.unmodifiable(paragraphs),
    );
  }
}
