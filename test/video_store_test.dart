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

  test('写入后 revision 递增，页面监听它刷新', () async {
    final store = ReadingStore();
    final before = store.revision.value;
    await store.saveVideoProgress(seriesId: 'v1', title: '剧A', episodeIndex: 0);
    expect(store.revision.value, greaterThan(before));
  });
}
