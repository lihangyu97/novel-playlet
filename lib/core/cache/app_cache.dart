import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_image_cache.dart';

/// 各类「可重建缓存」的占用（字节）。
///
/// 只统计缓存，不包含书架/阅读进度（`shared_preferences`）与内核的设备注册池
/// （`backend/config/`）——那些删了就要重新注册或丢用户数据，不属于缓存。
@immutable
class CacheUsage {
  const CacheUsage({
    this.video = 0,
    this.image = 0,
    this.chapter = 0,
    this.legacyLog = 0,
  });

  /// 内核 `src/`：已下载的剧集（密文 mp4 + 密钥 sidecar）与漫画图。
  final int video;

  /// 封面图磁盘缓存。
  final int image;

  /// 章节正文缓存。
  final int chapter;

  /// 早期调试探针遗留的 `Documents/diag.log`（当前代码不再写入）。
  final int legacyLog;

  int get total => video + image + chapter + legacyLog;

  bool get isEmpty => total == 0;
}

/// 缓存的位置、占用统计与清理。
///
/// 这些目录都在 App 沙盒里，删掉后按需重新下载/重新请求即可，所以统一收在这里
/// 做「看占用 + 手动清」。视频缓存的上限由内核控制（`MAX_VIDEO_CACHE_BYTES`，
/// 128 MB，每次下载后按最旧优先淘汰），这里只负责展示和手动清空。
class AppCache {
  AppCache({
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? documentsDirectory,
    Future<void> Function()? clearImageCache,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory,
       _clearImageCache = clearImageCache ?? _emptyImageCache;

  /// App 运行时用的单例；测试里可以 new 一个注入临时目录。
  static final AppCache instance = AppCache();

  static const _imageCacheKey = AppImageCache.cacheKey;
  static const _imageIndexName = '$_imageCacheKey.db';
  static const _videoDirName = 'src';
  static const _chapterDirName = 'reader_chapters';
  static const _legacyLogName = 'diag.log';

  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _documentsDirectory;
  final Future<void> Function() _clearImageCache;

  static Future<void> _emptyImageCache() => AppImageCache.manager.emptyCache();

  /// 内核运行目录（`<AppSupport>/backend`）。配置与设备池在这里，不能删。
  Future<Directory> _backendDir() async =>
      Directory('${(await _supportDirectory()).path}/backend');

  Future<Directory> _videoDir() async =>
      Directory('${(await _backendDir()).path}/$_videoDirName');

  Future<Directory> _chapterDir() async =>
      Directory('${(await _supportDirectory()).path}/$_chapterDirName');

  /// 封面缓存目录：不同 iOS 版本 path_provider 把"临时目录"指到 tmp 或
  /// Library/Caches，两个位置都查，按绝对路径去重——iOS 上 `getTemporaryDirectory()`
  /// 就是 `Library/Caches`，不去重会把同一份图片统计两遍（真机上曾显示
  /// 「封面 69 MB」，实际只有 26 MB）。
  Future<List<Directory>> _imageDirs() async {
    final seen = <String>{};
    final dirs = <Directory>[];
    Future<void> add(Directory dir) async {
      final path = dir.absolute.path;
      if (seen.add(path)) dirs.add(dir);
    }

    try {
      await add(Directory('${(await _temporaryDirectory()).path}/$_imageCacheKey'));
    } catch (_) {}
    try {
      final support = await _supportDirectory();
      await add(Directory('${support.parent.path}/Caches/$_imageCacheKey'));
    } catch (_) {}
    return dirs;
  }

  /// 封面缓存索引：`flutter_cache_manager` 把 sqflite 库放在 App Support。
  /// 同样按路径去重。
  Future<List<File>> _imageIndexFiles() async {
    final seen = <String>{};
    final files = <File>[];
    void add(File file) {
      if (seen.add(file.absolute.path)) files.add(file);
    }

    try {
      add(File('${(await _supportDirectory()).path}/$_imageIndexName'));
    } catch (_) {}
    try {
      add(File('${(await _temporaryDirectory()).path}/$_imageIndexName'));
    } catch (_) {}
    return files;
  }

  /// 统计当前占用。目录不存在就按 0 算。
  Future<CacheUsage> measure() async {
    return CacheUsage(
      video: await _dirSize(await _videoDir()),
      image:
          await _dirsSize(await _imageDirs()) +
          await _fileSizes(await _imageIndexFiles()),
      chapter: await _dirSize(await _chapterDir()),
      legacyLog: await _fileSizes([
        File('${(await _documentsDirectory()).path}/$_legacyLogName'),
      ]),
    );
  }

  /// 清空所有可重建缓存，返回释放的字节数。
  ///
  /// 只删缓存文件：`backend/config/`（设备池、过滤配置）与书架/进度都不动。
  /// 图片缓存先走 `CacheManager.emptyCache()`（连索引一起清，避免删了文件但
  /// 索引还指向它），再兜底扫一遍残留文件。
  Future<int> clear() async {
    final before = await measure();

    try {
      await _clearImageCache();
    } catch (error) {
      debugPrint('[cache] empty image cache failed: $error');
    }
    for (final dir in await _imageDirs()) {
      await _clearDir(dir);
    }
    for (final file in await _imageIndexFiles()) {
      await _deleteFile(file);
    }
    await _clearDir(await _videoDir());
    await _clearDir(await _chapterDir());
    await _deleteFile(
      File('${(await _documentsDirectory()).path}/$_legacyLogName'),
    );

    final after = await measure();
    final freed = before.total - after.total;
    return freed > 0 ? freed : 0;
  }

  Future<int> _dirSize(Directory dir) async {
    return _fileSizes(await _filesIn(dir));
  }

  Future<int> _dirsSize(List<Directory> dirs) async {
    var total = 0;
    for (final dir in dirs) {
      total += await _dirSize(dir);
    }
    return total;
  }

  Future<int> _fileSizes(List<File> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += await file.length();
      } catch (_) {
        // 并发删除/无权限：跳过即可，统计不需要精确到最后一字节。
      }
    }
    return total;
  }

  Future<List<File>> _filesIn(Directory dir) async {
    try {
      if (!await dir.exists()) return const [];
      final files = await dir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();
      return files;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _clearDir(Directory dir) async {
    for (final file in await _filesIn(dir)) {
      await _deleteFile(file);
    }
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就留着，下次进来再清；不要让清理入口报错。
    }
  }
}

/// 把字节数变成「339 MB」这类可读文案。
///
/// 只用于缓存统计这种粗粒度展示，所以 100 以上取整、以下保留 1 位小数。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 10 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
