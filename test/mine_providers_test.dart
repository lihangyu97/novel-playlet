import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_providers.dart';

/// 「我的」页数据通道拆分（CODE_REVIEW P1-5 回归）。
///
/// 小说与短剧合并成一条时间线 / 一个收藏夹之后，通道只剩三条：
/// - 写进度（阅读页防抖落盘、播放页换集）→ 刷新「历史」和「在看」（卡片上
///   的「读到第 N 章 / 看到第 N 集」就是进度列）；
/// - 加/移收藏 → 只刷新「收藏」；
/// - pin / 取消 pin → 只刷新「在看」。
/// 除「在看 / 历史」这一对之外互不牵连，否则保活的整页会跟着重建。
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

  test('在看卡片跟着阅读进度刷新', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '剑来',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    await store.togglePin(
      type: LibraryType.novel,
      sourceId: 'n1',
      title: '剑来',
    );

    var pinRebuilds = 0;
    container.listen(minePinsProvider, (_, _) => pinRebuilds++);
    var pins = await container.read(minePinsProvider.future);
    expect(pins.single.progressIndex, 0);
    await container.pump();
    pinRebuilds = 0;

    // 翻到第 5 章：卡片上的「读到第 N 章」必须跟着变，不能停在第 1 章。
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '剑来',
      cover: '',
      chapterId: 'c5',
      chapterIndex: 4,
    );
    await container.pump();

    expect(pinRebuilds, greaterThan(0), reason: '进度落盘要让在看列表重查');
    pins = await container.read(minePinsProvider.future);
    expect(pins.single.progressRef, 'c5');
    expect(pins.single.progressIndex, 4);
  });

  test('短剧在看同样跟着换集刷新', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    await store.saveVideoProgress(
      seriesId: 'series-1',
      title: '短剧甲',
      episodeIndex: 0,
    );
    await store.togglePin(
      type: LibraryType.playlet,
      sourceId: 'series-1',
      title: '短剧甲',
    );

    var pinRebuilds = 0;
    container.listen(minePinsProvider, (_, _) => pinRebuilds++);
    var pins = await container.read(minePinsProvider.future);
    expect(pins.single.progressIndex, 0);
    await container.pump();
    pinRebuilds = 0;

    await store.saveVideoProgress(
      seriesId: 'series-1',
      title: '短剧甲',
      episodeIndex: 4,
    );
    await container.pump();

    expect(pinRebuilds, greaterThan(0), reason: '换集要让在看列表重查');
    pins = await container.read(minePinsProvider.future);
    expect(pins.single.progressIndex, 4);
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

  test('历史预览只取 3 条，全部历史与条数各自完整', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    for (var i = 1; i <= 5; i++) {
      await store.saveProgress(
        bookId: 'b$i',
        bookTitle: '书$i',
        cover: '',
        chapterId: 'c$i',
        chapterIndex: i,
      );
    }

    final preview = await container.read(mineHistoryProvider.future);
    final all = await container.read(mineHistoryAllProvider.future);
    expect(preview.map((r) => r.sourceId), ['b5', 'b4', 'b3']);
    expect(all.map((r) => r.sourceId), ['b5', 'b4', 'b3', 'b2', 'b1']);
    expect(await container.read(mineHistoryCountProvider.future), 5);
  });

  test('收藏预览最多 6 个，全部收藏与条数各自完整', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    for (var i = 1; i <= 8; i++) {
      await store.addToShelf(NovelItem(id: 'b$i', title: '书$i'));
    }

    final preview = await container.read(mineCollectionPreviewProvider.future);
    final all = await container.read(mineCollectionProvider.future);
    expect(preview, hasLength(mineCollectionPreviewLimit));
    expect(preview.map((r) => r.sourceId), [
      'b8',
      'b7',
      'b6',
      'b5',
      'b4',
      'b3',
    ]);
    expect(all, hasLength(8));
    expect(await container.read(mineCollectionCountProvider.future), 8);
  });

  test('删除历史只刷新历史通道，不重读收藏', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = container.read(readingStoreProvider);
    await store.addToShelf(const NovelItem(id: 'n1', title: '书一'));
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '书一',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );

    var collectionRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineCollectionProvider, (_, _) => collectionRebuilds++);
    container.listen(mineHistoryAllProvider, (_, _) => historyRebuilds++);
    expect(await container.read(mineCollectionProvider.future), hasLength(1));
    expect(await container.read(mineHistoryAllProvider.future), hasLength(1));
    await container.pump();
    collectionRebuilds = 0;
    historyRebuilds = 0;

    await store.removeHistory(LibraryType.novel, 'n1');
    await container.pump();

    expect(collectionRebuilds, 0, reason: '删历史不该让收藏重查一遍库');
    expect(historyRebuilds, greaterThan(0));
    expect(await container.read(mineHistoryAllProvider.future), isEmpty);
    expect(await container.read(mineCollectionProvider.future), hasLength(1));
  });
}
