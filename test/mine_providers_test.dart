import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_providers.dart';

/// 「我的」页数据通道拆分（CODE_REVIEW P1-5 回归）。
///
/// 小说与短剧合并成一条时间线 / 一个收藏夹之后，通道只剩两条：
/// - 写进度（阅读页防抖落盘、播放页换集）→ 只刷新「历史」；
/// - 加/移收藏 → 只刷新「收藏」。
/// 两条互不牵连，否则保活的整页会跟着重建。
void main() {
  test('保存阅读进度只刷新历史，不重读收藏', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(readingStoreProvider)
        .addToShelf(const NovelItem(id: '1', title: '剑来'));

    var collectionRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineCollectionProvider, (_, _) => collectionRebuilds++);
    container.listen(mineHistoryProvider, (_, _) => historyRebuilds++);

    expect(await container.read(mineCollectionProvider.future), hasLength(1));
    expect(await container.read(mineHistoryProvider.future), isEmpty);
    await container.pump();
    collectionRebuilds = 0;
    historyRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .saveProgress(
          bookId: '1',
          bookTitle: '剑来',
          cover: '',
          chapterId: 'c1',
          chapterIndex: 0,
        );
    await container.pump();

    expect(collectionRebuilds, 0, reason: '进度落盘不能让收藏列表重查一遍库');
    expect(historyRebuilds, greaterThan(0), reason: '历史必须跟着进度刷新');
    expect(
      (await container.read(mineHistoryProvider.future)).map((r) => r.sourceId),
      ['1'],
    );
  });

  test('加入收藏只刷新收藏，不重读历史', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var collectionRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineCollectionProvider, (_, _) => collectionRebuilds++);
    container.listen(mineHistoryProvider, (_, _) => historyRebuilds++);

    expect(await container.read(mineCollectionProvider.future), isEmpty);
    expect(await container.read(mineHistoryProvider.future), isEmpty);
    await container.pump();
    collectionRebuilds = 0;
    historyRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .addToShelf(const NovelItem(id: '1', title: '剑来'));
    await container.pump();

    expect(historyRebuilds, 0, reason: '收藏写入不该让历史重读一遍本地数据');
    expect(collectionRebuilds, greaterThan(0), reason: '收藏必须刷新');
    expect(await container.read(mineCollectionProvider.future), hasLength(1));
  });

  test('短剧观看进度同样只刷新历史', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(readingStoreProvider)
        .addVideoToShelf(const VideoSeries(id: 'v1', title: '剧A'));

    var collectionRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineCollectionProvider, (_, _) => collectionRebuilds++);
    container.listen(mineHistoryProvider, (_, _) => historyRebuilds++);
    expect(await container.read(mineCollectionProvider.future), hasLength(1));
    expect(await container.read(mineHistoryProvider.future), isEmpty);
    await container.pump();
    collectionRebuilds = 0;
    historyRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .saveVideoProgress(seriesId: 'v1', title: '剧A', episodeIndex: 3);
    await container.pump();

    expect(collectionRebuilds, 0);
    expect(historyRebuilds, greaterThan(0));
    final history = await container.read(mineHistoryProvider.future);
    expect(history.single.progressIndex, 3);
  });

  test('历史按最近一次阅读/观看混排，小说与短剧都在同一条线上', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '小说一',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 2,
    );
    await store.saveVideoProgress(
      seriesId: 'p1',
      title: '短剧一',
      episodeIndex: 4,
    );

    final history = await container.read(mineHistoryProvider.future);
    expect(history.map((r) => r.sourceId), ['p1', 'n1']);
    expect(history.first.type.isPlaylet, isTrue);
    expect(history.last.type.isPlaylet, isFalse);
  });
}
