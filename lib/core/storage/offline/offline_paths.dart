import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 离线 pinned 区的目录布局与原子写工具。
///
/// 布局见 docs/offline-cache.md §4.1：
/// `<Application Support>/offline/{novel,video}/<key>/`。
/// 与自动缓存（`reader_chapters/`、`backend/src/`、`Caches/`）物理隔离，
/// **不参与任何自动淘汰 / TTL / 体积裁剪**，只能由用户显式删除。
///
/// 所有方法只算路径、不做 IO；需要目录存在的地方由调用方用
/// [ensureDirectory] 创建（读路径不能顺手建目录，否则空目录会被当成孤立项）。
class OfflinePaths {
  OfflinePaths({Future<Directory> Function()? rootDirectory})
    : _rootDirectory = rootDirectory ?? _defaultRootDirectory;

  final Future<Directory> Function() _rootDirectory;

  static Future<Directory> _defaultRootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/offline');
  }

  /// 离线区根目录（`.../offline`）；可能存在也可能不存在。
  Future<Directory> root() => _rootDirectory();

  /// 小说离线区根目录（`offline/novel`）。
  Future<Directory> novelDir() async =>
      Directory('${(await root()).path}/novel');

  /// 短剧离线区根目录（`offline/video`）。
  Future<Directory> videoDir() async =>
      Directory('${(await root()).path}/video');

  /// 一本书的离线目录（`offline/novel/<bookKey>`）。
  Future<Directory> bookDir(String bookId) async =>
      Directory('${(await novelDir()).path}/${encodeOfflineKey(bookId)}');

  /// 一部剧的离线目录（`offline/video/<seriesKey>`）。
  Future<Directory> seriesDir(String seriesId) async =>
      Directory('${(await videoDir()).path}/${encodeOfflineKey(seriesId)}');
}

/// id → 文件名安全的 Base64URL（去掉 `=`）。
///
/// 沿用 `reader_chapter_cache.dart` 的做法：id 里的 `/`、`:` 等不能进路径。
String encodeOfflineKey(String id) =>
    base64Url.encode(utf8.encode(id)).replaceAll('=', '');

/// 确保目录存在（写路径用；读路径不要调）。
Future<Directory> ensureDirectory(Directory directory) async {
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

/// 原子写 JSON：先写 `.part` 临时文件，flush 后 rename；失败删临时文件再抛。
///
/// 半截文件只会以 `.part` 形态存在（启动/管理页可清理），目标文件要么是旧
/// 版本要么是新版本，不会出现坏 JSON。
Future<void> writeJsonAtomically(File file, Map<String, dynamic> json) =>
    _writeAtomically(
      file,
      (temp) => temp.writeAsString(jsonEncode(json), flush: true),
    );

/// 原子写字节（封面等小文件）。
Future<void> writeBytesAtomically(File file, List<int> bytes) =>
    _writeAtomically(file, (temp) => temp.writeAsBytes(bytes, flush: true));

Future<void> _writeAtomically(
  File file,
  Future<File> Function(File temp) write,
) async {
  await ensureDirectory(file.parent);
  final temp = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
  );
  try {
    await write(temp);
    // rename 在同目录内是原子的；目标已存在时 POSIX 会覆盖。
    await temp.rename(file.path);
  } catch (_) {
    await deleteQuietly(temp);
    rethrow;
  }
}

/// 递归统计目录内普通文件总字节。目录不存在 / 读失败按 0 计（统计不能抛）。
Future<int> directoryBytes(Directory directory) async {
  var total = 0;
  try {
    if (!await directory.exists()) return 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } catch (_) {
        // 单个文件 stat 失败不影响整体统计。
      }
    }
  } catch (_) {
    // 目录不可读等同于空。
  }
  return total;
}

/// 静默删除文件（不存在/失败都不抛）。
Future<void> deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 自愈是尽力而为，失败留给下次。
  }
}

/// 静默删除目录（不存在/失败都不抛）。
Future<void> deleteDirectoryQuietly(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {
    // 自愈是尽力而为，失败留给下次。
  }
}

/// 列出一级子目录；目录不存在/不可读返回空列表。
Future<List<Directory>> listChildDirectories(Directory parent) async {
  final out = <Directory>[];
  try {
    if (!await parent.exists()) return out;
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is Directory) out.add(entity);
    }
  } catch (_) {
    // 不可读等同于空。
  }
  return out;
}
