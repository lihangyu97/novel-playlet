import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/models/chapter.dart';

/// 短剧离线区存储：manifest / part→commit 原子落盘 / 校正 / 自愈。
void main() {
  late Directory tempRoot;
  late OfflinePaths paths;
  late OfflineSeriesStore store;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('offline_series_test_');
    paths = OfflinePaths(rootDirectory: () async => tempRoot);
    store = OfflineSeriesStore(paths: paths);
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
  });

  OfflineSeries series({
    String seriesId = 's1',
    int episodes = 3,
    int completed = 0,
    int bytes = 0,
  }) => OfflineSeries(
    seriesId: seriesId,
    title: '测试短剧',
    cover: 'https://example.com/cover.jpg',
    episodes: [
      for (var i = 0; i < episodes; i++)
        OfflineEpisode(id: 'e$i', title: '第${i + 1}集', index: i),
    ],
    completed: completed,
    bytes: bytes,
  );

  test('begin 写完整 manifest，read 原样读回', () async {
    await store.begin(series());
    final loaded = await store.read('s1');
    expect(loaded, isNotNull);
    expect(loaded!.seriesId, 's1');
    expect(loaded.total, 3);
    expect(loaded.episodes.map((e) => e.id), ['e0', 'e1', 'e2']);
    expect(loaded.schema, offlineSchema);
    expect(loaded.kind, offlineKindVideo);
  });

  test('partFile → commitEpisode 原子落盘', () async {
    await store.begin(series());
    final part = await store.partFile('s1', 'e1');
    expect(part.path.endsWith('.mp4.part'), isTrue);
    await part.writeAsBytes([1, 2, 3, 4]);

    expect(
      await store.hasEpisode('s1', 'e1'),
      isFalse,
      reason: '未 commit 前不算缓存',
    );
    await store.commitEpisode('s1', 'e1', bytes: 4);
    expect(await store.hasEpisode('s1', 'e1'), isTrue);
    expect(await part.exists(), isFalse, reason: 'part 应被 rename 掉');

    final file = await store.episodeFile('s1', 'e1');
    expect(file, isNotNull);
    expect(await file!.length(), 4);
  });

  test('commit 时 part 缺失抛错（下载器会按失败处理）', () async {
    expect(
      () => store.commitEpisode('s1', 'e9', bytes: 1),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('0 字节 mp4 视为坏文件', () async {
    final file = await store.episodeFilePath('s1', 'e0');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const []);
    expect(await store.hasEpisode('s1', 'e0'), isFalse);
    expect(await store.episodeFileIfCached('s1', 'e0'), isNull);
  });

  test('missingEpisodeIds 只看正式文件是否存在', () async {
    await store.begin(series());
    final part = await store.partFile('s1', 'e0');
    await part.writeAsBytes([1, 2]);
    await store.commitEpisode('s1', 'e0', bytes: 2);
    final missing = await store.missingEpisodeIds('s1', [
      const Chapter(id: 'e0', title: '一'),
      const Chapter(id: 'e1', title: '二'),
    ]);
    expect(missing, ['e1']);
  });

  test('reconcile 校正每集 cached/bytes 与整体 completed/bytes', () async {
    await store.begin(series());
    final part = await store.partFile('s1', 'e0');
    await part.writeAsBytes([1, 2, 3]);
    await store.commitEpisode('s1', 'e0', bytes: 3);
    // e1 写个 0 字节坏文件，e2 缺失。
    final bad = await store.episodeFilePath('s1', 'e1');
    await bad.writeAsBytes(const []);

    await store.reconcile('s1');
    final loaded = await store.read('s1');
    expect(loaded!.completed, 1);
    expect(loaded.bytes, 3);
    expect(loaded.episodes.map((e) => e.cached), [true, false, false]);
    expect(loaded.episodes.first.bytes, 3);
  });

  test('reconcile 清理残留 .part', () async {
    await store.begin(series());
    final part = await store.partFile('s1', 'e2');
    await part.writeAsBytes([1]);
    await store.reconcile('s1');
    expect(await part.exists(), isFalse);
  });

  test('stats 只累加 manifest 的 bytes 与条数', () async {
    await store.begin(series(seriesId: 's1', bytes: 1000));
    await store.begin(series(seriesId: 's2', bytes: 2000));
    final stats = await store.stats();
    expect(stats.count, 2);
    expect(stats.bytes, 3000);
    expect(stats.capBytes, OfflineSeriesStore.videoCapBytes);
    expect(OfflineSeriesStore.videoCapBytes, 3 * 1024 * 1024 * 1024);
  });

  test('summaries 跳过孤儿目录，pruneOrphans 清掉它', () async {
    await store.begin(series(seriesId: 's1', completed: 1));
    final orphan = await paths.seriesDir('orphan');
    await orphan.create(recursive: true);

    expect((await store.summaries()).map((s) => s.seriesId), ['s1']);
    expect(await store.pruneOrphans(), 1);
    expect(await orphan.exists(), isFalse);
    expect(await store.read('s1'), isNotNull);
  });

  test('delete / clearAll 只动短剧区', () async {
    await store.begin(series(seriesId: 's1'));
    await store.begin(series(seriesId: 's2'));
    await store.delete('s1');
    expect(await store.read('s1'), isNull);
    expect(await store.read('s2'), isNotNull);
    await store.clearAll();
    expect(await store.summaries(), isEmpty);
  });

  test('schema 不认识当没有缓存（不删文件）', () async {
    final dir = await paths.seriesDir('s9');
    await dir.create(recursive: true);
    await File('${dir.path}/series.json').writeAsString(
      jsonEncode({'schema': 99, 'kind': 'video', 'seriesId': 's9'}),
    );
    expect(await store.read('s9'), isNull);
    expect(await File('${dir.path}/series.json').exists(), isTrue);
  });
}
