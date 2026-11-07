import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/cache/app_cache.dart';

/// 缓存统计/清理的回归：只删「可重建」的缓存，用户数据和设备注册池必须留着。
///
/// 用临时目录注入（AppCache 的三个目录都可替换），不依赖 path_provider 插件，
/// 所以能在 host 上直接跑。真机实测（iPhone 13）清理前：视频 339 MB + 封面
/// 40 MB + 章节 16 KB + 遗留日志 116 KB = 395 MB，正是这个入口要解决的问题。
void main() {
  test('measure 统计各缓存目录，clear 只删缓存不动用户数据', () async {
    final root = Directory.systemTemp.createTempSync('app_cache_test');
    addTearDown(() => root.deleteSync(recursive: true));

    final support = Directory('${root.path}/support')..createSync();
    final tmp = Directory('${root.path}/tmp')..createSync();
    final docs = Directory('${root.path}/docs')..createSync();

    // 内核 src/：剧集 + 密钥 sidecar + 半截下载。
    final videoDir = Directory('${support.path}/backend/src')
      ..createSync(recursive: true);
    File('${videoDir.path}/a.mp4').writeAsBytesSync(List.filled(1000, 1));
    File('${videoDir.path}/a.key').writeAsBytesSync(List.filled(100, 2));
    File('${videoDir.path}/b.part').writeAsBytesSync(List.filled(500, 3));

    // 不能删的：设备池 / 运行时配置。
    final configDir = Directory('${support.path}/backend/config')
      ..createSync(recursive: true);
    File('${configDir.path}/device_pool.json').writeAsStringSync('{"dev":1}');
    File('${configDir.path}/config.json').writeAsStringSync('{"port":0}');

    // 章节正文缓存。
    final chapterDir = Directory('${support.path}/reader_chapters')
      ..createSync(recursive: true);
    File('${chapterDir.path}/c1.json').writeAsStringSync('{}');

    // 封面缓存：tmp 下的文件目录、Caches 下的文件目录、Support 里的索引库。
    final tmpImage = Directory('${tmp.path}/libCachedImageData')
      ..createSync(recursive: true);
    File('${tmpImage.path}/img-a').writeAsBytesSync(List.filled(300, 4));
    final cachesImage = Directory('${root.path}/Caches/libCachedImageData')
      ..createSync(recursive: true);
    File('${cachesImage.path}/img-b').writeAsBytesSync(List.filled(200, 5));
    final imageIndex = File('${support.path}/libCachedImageData.db')
      ..writeAsBytesSync(List.filled(10, 6));

    // 早期调试探针遗留的日志。
    File('${docs.path}/diag.log').writeAsStringSync('x');

    // 离线缓存区（offline/）：用户主动下载的数据，不是可重建缓存。
    // clear() 绝不能碰它（docs/offline-cache.md 的隔离不变式）。
    final offlineNovel = Directory('${support.path}/offline/novel/b1')
      ..createSync(recursive: true);
    File('${offlineNovel.path}/book.json').writeAsStringSync('{"bookId":"b1"}');
    File('${offlineNovel.path}/c1.json').writeAsStringSync('{"id":"c1"}');
    final offlineVideo = Directory('${support.path}/offline/video/s1')
      ..createSync(recursive: true);
    File('${offlineVideo.path}/series.json')
        .writeAsStringSync('{"seriesId":"s1"}');
    File('${offlineVideo.path}/e1.mp4').writeAsBytesSync(List.filled(700, 7));

    final cache = AppCache(
      supportDirectory: () async => support,
      temporaryDirectory: () async => tmp,
      documentsDirectory: () async => docs,
      clearImageCache: () async {},
    );

    final usage = await cache.measure();
    expect(usage.video, 1600, reason: 'mp4 + key + part 都要算进视频缓存');
    expect(usage.image, 510, reason: '两个图片目录 + sqflite 索引');
    expect(usage.chapter, 2);
    expect(usage.legacyLog, 1);
    expect(usage.total, 2113);

    final freed = await cache.clear();
    expect(freed, usage.total, reason: 'clear 返回值应为实际释放的字节数');
    expect((await cache.measure()).total, 0, reason: '清完应统计为 0');

    // 缓存全没了。
    expect(File('${videoDir.path}/a.mp4').existsSync(), isFalse);
    expect(File('${videoDir.path}/a.key').existsSync(), isFalse);
    expect(File('${chapterDir.path}/c1.json').existsSync(), isFalse);
    expect(File('${tmpImage.path}/img-a').existsSync(), isFalse);
    expect(File('${cachesImage.path}/img-b').existsSync(), isFalse);
    expect(imageIndex.existsSync(), isFalse);
    expect(File('${docs.path}/diag.log').existsSync(), isFalse);

    // 用户数据/设备池必须还在（否则要重新注册设备、丢书架）。
    expect(File('${configDir.path}/device_pool.json').existsSync(), isTrue);
    expect(File('${configDir.path}/config.json').existsSync(), isTrue);

    // 离线缓存区必须原样保留：体积不进「自动缓存」统计、文件不被清理。
    expect(File('${offlineNovel.path}/book.json').existsSync(), isTrue);
    expect(File('${offlineNovel.path}/c1.json').existsSync(), isTrue);
    expect(File('${offlineVideo.path}/series.json').existsSync(), isTrue);
    expect(File('${offlineVideo.path}/e1.mp4').existsSync(), isTrue);
    expect(usage.total, 1600 + 510 + 2 + 1, reason: '离线区不计入自动缓存占用');
    expect(videoDir.existsSync(), isTrue, reason: '目录本身保留，内核还要往里写');
  });

  test('iOS 上临时目录就是 Library/Caches：图片缓存不能算两遍', () async {
    final root = Directory.systemTemp.createTempSync('app_cache_ios_test');
    addTearDown(() => root.deleteSync(recursive: true));

    // iOS 的布局：<container>/Library/Application Support 与 <container>/Library/Caches，
    // path_provider 的 getTemporaryDirectory() 返回后者。
    final library = Directory('${root.path}/Library')..createSync();
    final support = Directory('${library.path}/Application Support')
      ..createSync();
    final caches = Directory('${library.path}/Caches')..createSync();
    final docs = Directory('${root.path}/Documents')..createSync();

    final imageDir = Directory('${caches.path}/libCachedImageData')
      ..createSync();
    File('${imageDir.path}/img').writeAsBytesSync(List.filled(400, 1));

    final cache = AppCache(
      supportDirectory: () async => support,
      temporaryDirectory: () async => caches,
      documentsDirectory: () async => docs,
      clearImageCache: () async {},
    );

    expect(
      (await cache.measure()).image,
      400,
      reason: '两个候选目录在 iOS 上指向同一处，必须去重',
    );
  });

  test('统计超过一批的文件时按固定批次并发 stat，总数不变', () async {
    final root = Directory.systemTemp.createTempSync('app_cache_batch_test');
    addTearDown(() => root.deleteSync(recursive: true));

    final support = Directory('${root.path}/support')..createSync();
    final tmp = Directory('${root.path}/tmp')..createSync();
    final docs = Directory('${root.path}/docs')..createSync();
    final chapterDir = Directory('${support.path}/reader_chapters')
      ..createSync(recursive: true);

    // 97 个文件跨 4 个 stat 批次（32/32/32/1），大小按序号递增。
    var expected = 0;
    for (var i = 0; i < 97; i++) {
      final size = i + 1;
      File('${chapterDir.path}/c$i.json')
          .writeAsBytesSync(List.filled(size, 0));
      expected += size;
    }

    final cache = AppCache(
      supportDirectory: () async => support,
      temporaryDirectory: () async => tmp,
      documentsDirectory: () async => docs,
      clearImageCache: () async {},
    );

    expect(
      (await cache.measure()).chapter,
      expected,
      reason: '并发分批只改等待方式，统计口径（字节总数）必须一致',
    );
  });

  test('formatBytes 展示口径', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(16 * 1024), '16 KB');
    expect(formatBytes(40 * 1024 * 1024), '40 MB');
    expect(formatBytes(339 * 1024 * 1024), '339 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
  });
}
