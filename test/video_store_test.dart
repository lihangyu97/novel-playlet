import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 短剧本地数据：收藏 / 观看进度 / 最近观看（最多 3 条）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('短剧收藏：加入、去重、移出', () async {
    final store = ReadingStore();
    final a = VideoSeries(
      id: 'v1',
      title: '剧A',
      cover: 'https://example.com/a.jpg',
      episodeCount: 12,
    );
    const b = VideoSeries(id: 'v2', title: '剧B');

    await store.addVideoToShelf(a);
    await store.addVideoToShelf(b);
    await store.addVideoToShelf(a); // 已收藏不重复写入
    final shelf = await store.videoShelf();
    // 与小说书架一致：新加入的排在最前。
    expect(shelf.map((item) => item.id), ['v2', 'v1']);
    final storedA = shelf.firstWhere((item) => item.id == 'v1');
    expect(storedA.episodeCount, 12);
    expect(storedA.cover, 'https://example.com/a.jpg');
    expect(await store.isVideoOnShelf('v1'), isTrue);

    await store.removeVideoFromShelf('v1');
    expect((await store.videoShelf()).map((item) => item.id), ['v2']);
    expect(await store.isVideoOnShelf('v1'), isFalse);
  });

  test('最近观看最多 3 条，同一部剧只保留最新进度', () async {
    final store = ReadingStore();
    for (var i = 0; i < 5; i++) {
      await store.saveVideoProgress(
        seriesId: 'v$i',
        title: '剧$i',
        episodeIndex: i,
      );
    }

    var history = await store.videoHistory();
    expect(history.length, 3, reason: '观看历史与小说最近阅读一样最多 3 条');
    expect(history.map((item) => item.seriesId), ['v4', 'v3', 'v2']);

    // 重看旧剧：进度更新并顶到最前，不新增条目。
    await store.saveVideoProgress(seriesId: 'v3', title: '剧3', episodeIndex: 9);
    history = await store.videoHistory();
    expect(history.length, 3);
    expect(history.map((item) => item.seriesId), ['v3', 'v4', 'v2']);
    expect(history.first.episodeIndex, 9);

    final progress = await store.videoProgress('v3');
    expect(progress?.episodeIndex, 9);
  });

  test('写入后 videoRevision 递增，页面监听它刷新', () async {
    final store = ReadingStore();
    final before = store.videoRevision.value;
    await store.saveVideoProgress(seriesId: 'v1', title: '剧A', episodeIndex: 0);
    expect(store.videoRevision.value, greaterThan(before));
  });

  test('看视频只 bump videoRevision，不动小说侧计数器', () async {
    final store = ReadingStore();
    final novelBefore = store.novelRevision.value;
    final videoBefore = store.videoRevision.value;

    await store.addVideoToShelf(const VideoSeries(id: 'v1', title: '剧A'));
    await store.saveVideoProgress(seriesId: 'v1', title: '剧A', episodeIndex: 1);
    await store.removeVideoFromShelf('v1');

    expect(store.videoRevision.value, videoBefore + 3);
    // 短剧侧写入不应让小说书架 / 最近阅读跟着重读一遍本地数据。
    expect(store.novelRevision.value, novelBefore);
  });

  test('阅读进度表按最近更新只保留 200 本，最近阅读不受影响', () async {
    const limit = ReadingStore.progressLimit;
    final base = DateTime(2020, 1, 1);
    Map<String, dynamic> entry(int i) => ReadingProgress(
      bookId: 'book$i',
      bookTitle: '书$i',
      cover: '',
      chapterId: 'chapter$i',
      chapterIndex: i,
      updatedAt: base.add(Duration(minutes: i)),
    ).toJson();

    // 老版本没有上限，进度表可能已经超了；再存一本应立刻收敛到上限。
    final progress = <String, dynamic>{
      for (var i = 0; i < limit + 5; i++) 'book$i': entry(i),
    };
    final recent = [entry(limit + 4), entry(limit + 3), entry(limit + 2)];
    SharedPreferences.setMockInitialValues({
      'reading_progress_v1': jsonEncode(progress),
      'recent_reading_v1': jsonEncode(recent),
    });

    final store = ReadingStore();
    await store.saveProgress(
      bookId: 'book-new',
      bookTitle: '新书',
      cover: '',
      chapterId: 'chapter-new',
      chapterIndex: 0,
    );

    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(
      prefs.getString('reading_progress_v1')!,
    ) as Map<String, dynamic>;
    expect(stored.length, limit, reason: '进度表必须有上限，否则每次保存都全量重写越来越大的 JSON');
    // 上限 + 1 本新书：淘汰最旧的 6 本。
    for (var i = 0; i < 6; i++) {
      expect(stored.containsKey('book$i'), isFalse, reason: 'book$i 最旧，应被淘汰');
    }
    expect(stored.containsKey('book-new'), isTrue);
    expect(await store.progress('book6'), isNotNull);
    expect(await store.progress('book0'), isNull);

    // 最近阅读是独立表，不跟着进度 LRU 被裁掉。
    expect((await store.recent()).map((item) => item.bookId), [
      'book-new',
      'book204',
      'book203',
    ]);
    expect(await store.lastReadBookId(), 'book-new');
  });
}
