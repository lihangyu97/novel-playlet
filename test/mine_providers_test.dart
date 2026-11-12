import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_drama_providers.dart';
import 'package:novel_playlet/features/mine/mine_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的」页数据通道拆分（CODE_REVIEW P1-5 回归）。
///
/// 阅读页每 400ms 落一次进度：如果它让书架 provider 失效，保活的「我的」页
/// 就要重新解码 shared_preferences 的书架表并重建整片书架网格。这里用订阅
/// 计数锁住窗口边界——
/// - 写阅读进度：只能刷新「最近阅读」通道；
/// - 加/移书架：只能刷新「书架」通道；
/// - 短剧侧同理（观看进度 vs 收藏）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('保存阅读进度只刷新最近阅读，不重读书架', () async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        {'id': '1', 'title': '剑来', 'cover': '', 'author': '烽火戏诸侯'},
      ]),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var shelfRebuilds = 0;
    var recentRebuilds = 0;
    container.listen(mineShelfProvider, (_, _) => shelfRebuilds++);
    container.listen(mineRecentProvider, (_, _) => recentRebuilds++);

    // 先等首屏两个 provider 构建完成，再把计数清零开始断言。
    expect(await container.read(mineShelfProvider.future), hasLength(1));
    expect(await container.read(mineRecentProvider.future), isEmpty);
    await container.pump();
    shelfRebuilds = 0;
    recentRebuilds = 0;

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

    expect(shelfRebuilds, 0, reason: '进度落盘不能让书架 provider 失效（否则书架网格整体重建）');
    expect(recentRebuilds, greaterThan(0), reason: '最近阅读必须跟着进度刷新');
    expect(
      (await container.read(mineRecentProvider.future)).map((p) => p.bookId),
      ['1'],
    );
  });

  test('加入书架只刷新书架，不重读最近阅读', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var shelfRebuilds = 0;
    var recentRebuilds = 0;
    container.listen(mineShelfProvider, (_, _) => shelfRebuilds++);
    container.listen(mineRecentProvider, (_, _) => recentRebuilds++);

    expect(await container.read(mineShelfProvider.future), isEmpty);
    expect(await container.read(mineRecentProvider.future), isEmpty);
    await container.pump();
    shelfRebuilds = 0;
    recentRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .addToShelf(const NovelItem(id: '1', title: '剑来'));
    await container.pump();

    expect(recentRebuilds, 0, reason: '书架写入不该让最近阅读重读一遍本地数据');
    expect(shelfRebuilds, greaterThan(0), reason: '书架必须刷新');
    expect(await container.read(mineShelfProvider.future), hasLength(1));
  });

  test('保存观看进度只刷新最近观看，不重读收藏', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var shelfRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineDramaShelfProvider, (_, _) => shelfRebuilds++);
    container.listen(mineDramaHistoryProvider, (_, _) => historyRebuilds++);

    expect(await container.read(mineDramaShelfProvider.future), isEmpty);
    expect(await container.read(mineDramaHistoryProvider.future), isEmpty);
    await container.pump();
    shelfRebuilds = 0;
    historyRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .saveVideoProgress(seriesId: 'v1', title: '剧A', episodeIndex: 1);
    await container.pump();

    expect(shelfRebuilds, 0, reason: '观看进度落盘不能让收藏 provider 失效（否则收藏网格整体重建）');
    expect(historyRebuilds, greaterThan(0), reason: '最近观看必须跟着进度刷新');
    expect(
      (await container.read(mineDramaHistoryProvider.future))
          .map((h) => h.seriesId),
      ['v1'],
    );
  });

  test('加入收藏只刷新收藏，不重读最近观看', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var shelfRebuilds = 0;
    var historyRebuilds = 0;
    container.listen(mineDramaShelfProvider, (_, _) => shelfRebuilds++);
    container.listen(mineDramaHistoryProvider, (_, _) => historyRebuilds++);

    expect(await container.read(mineDramaShelfProvider.future), isEmpty);
    expect(await container.read(mineDramaHistoryProvider.future), isEmpty);
    await container.pump();
    shelfRebuilds = 0;
    historyRebuilds = 0;

    await container
        .read(readingStoreProvider)
        .addVideoToShelf(const VideoSeries(id: 'v1', title: '剧A'));
    await container.pump();

    expect(historyRebuilds, 0, reason: '收藏变更不该让最近观看重读一遍本地数据');
    expect(shelfRebuilds, greaterThan(0), reason: '收藏必须刷新');
    expect(await container.read(mineDramaShelfProvider.future), hasLength(1));
  });
}
