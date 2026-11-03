import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 封面图磁盘缓存。
///
/// `cached_network_image` 默认用的是 `flutter_cache_manager` 的
/// `libCachedImageData` 缓存（stale 30 天 / 最多 200 个对象）。但封面是
/// 1080~1440 宽的原图（单张 1~3 MB），200 张就可能上 GB；真机上曾观察到
/// 一次积累到 80 MB。这里做三件事：
///   1. 更换同名缓存配置：7 天过期、最多 120 个对象（复用已有目录/索引）；
///   2. 启动时按"总体积"兜底裁剪：超过 [maxBytes] 就按 mtime 删最旧文件，
///      直到降到 [targetBytes] 以下（防止短时间内大量浏览把缓存堆起来）；
///   3. 封面 URL 只用于展示，删掉旧文件后需要时自然会重新下载。
class AppImageCache {
  AppImageCache._();

  static const cacheKey = 'libCachedImageData';

  /// 80 MB 时触发裁剪（真机曾达到 79.8 MB）。
  static const int maxBytes = 40 * 1024 * 1024;

  /// 裁剪目标：留 25 MB 常用封面。
  static const int targetBytes = 25 * 1024 * 1024;

  static final CacheManager manager = CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 120,
    ),
  );

  static bool _trimmed = false;

  /// 启动时调用一次；不阻塞启动，失败静默。
  static Future<void> trimOnStart() async {
    if (_trimmed) return;
    _trimmed = true;
    try {
      final dirs = await _candidateDirs();
      for (final dir in dirs) {
        await _trimDir(dir);
      }
    } catch (error) {
      debugPrint('[image-cache] trim failed: $error');
    }
  }

  /// 缓存目录在临时目录下；不同 iOS 版本 path_provider 指向 tmp 或
  /// Library/Caches，两个位置都查一遍。
  static Future<List<Directory>> _candidateDirs() async {
    final dirs = <Directory>[];
    try {
      final temp = await getTemporaryDirectory();
      dirs.add(Directory('${temp.path}/$cacheKey'));
    } catch (_) {}
    try {
      final support = await getApplicationSupportDirectory();
      dirs.add(Directory('${support.parent.path}/Caches/$cacheKey'));
    } catch (_) {}
    return dirs.where((dir) => dir.existsSync()).toList();
  }

  static Future<void> _trimDir(Directory dir) async {
    final files = await dir
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    if (files.isEmpty) return;

    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      entries.add((
        file: file,
        size: stat.size,
        modified: stat.modified,
      ));
      total += stat.size;
    }
    if (total <= maxBytes) return;

    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var remaining = total;
    for (final entry in entries) {
      if (remaining <= targetBytes) break;
      try {
        await entry.file.delete();
        remaining -= entry.size;
      } catch (_) {
        // 删不掉就跳过；下次启动再试。
      }
    }
    debugPrint(
      '[image-cache] trimmed ${(total - remaining) ~/ 1024}KB '
      '(${total ~/ 1024}KB -> ${remaining ~/ 1024}KB)',
    );
  }
}
