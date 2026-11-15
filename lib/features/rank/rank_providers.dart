import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/rank.dart';
import '../recommend/recommend_category.dart';

/// 首页榜单目录：藏在小说首页 payload 里，整个 App 进程内复用一份。
///
/// 失败不吞：首页预览卡片自己降级为不展示；榜单页用错误态 + 重试
///（`ref.invalidate(rankCatalogProvider)`）。
final rankCatalogProvider = FutureProvider<RankCatalog>((ref) async {
  return ref.read(apiClientProvider).rankCatalog();
});

/// 某个首页分类对应的榜：小说 → 推荐榜、短剧 → 短剧榜、漫剧 → 漫剧榜。
///
/// 目录里按 `rank_algo` 找；找不到时退回同 `genre_tab` 的第一档，避免上游
/// 改榜名后整张卡片消失。
RankTab? rankTabForCategory(RankCatalog catalog, RecommendCategory category) {
  final int preferredAlgo;
  final int preferredGenre;
  switch (category) {
    case RecommendCategory.novel:
      preferredAlgo = 101;
      preferredGenre = 2;
    case RecommendCategory.drama:
      preferredAlgo = 502;
      preferredGenre = 4;
    case RecommendCategory.anime:
      preferredAlgo = 550;
      preferredGenre = 5;
  }
  return catalog.tabForAlgo(preferredAlgo) ??
      catalog.tabForGenreTab(preferredGenre);
}

/// 首页榜单卡片的数据（榜名 + 首屏条目）。
@immutable
class RankPreviewData {
  const RankPreviewData({required this.tab, required this.board});

  final RankTab tab;
  final RankBoard board;
}

/// 首页三个分类的榜单预览：取首屏（内核一页 12 条），卡片铺前 10 条。
///
/// 失败/空榜一律不展示：首页的榜单是锦上添花，不能因为榜单接口挂掉把推荐流
/// 也打出错误态。非 autoDispose：三个分类各自只拉一次首屏，切 tab 回来不
/// 重复请求（榜单页会重新拉自己的第一页）。
///
/// 正因为结果（包括「失败」）会缓存整个 App 会话，这里**失败或空榜再重试
/// 一次**：一次网络抖动不该让某个分类的榜单永久消失（实测短剧/漫剧榜这种
/// 情况出现过）。两次都拿不到才真正收起。
final rankPreviewProvider =
    FutureProvider.family<RankPreviewData?, RecommendCategory>((
      ref,
      category,
    ) async {
      final catalog = await ref.watch(rankCatalogProvider.future);
      if (catalog.isEmpty) return null;
      final tab = rankTabForCategory(catalog, category);
      if (tab == null || catalog.rankId.isEmpty) return null;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final board = await ref
              .read(apiClientProvider)
              .rankBoard(
                rankId: catalog.rankId,
                algo: tab.algo,
                genreTab: tab.genreTab,
              );
          if (board.entries.isNotEmpty) {
            return RankPreviewData(tab: tab, board: board);
          }
        } catch (_) {
          // 交给下一轮重试；第二轮还失败就按「没有榜单」处理。
        }
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
      }
      return null;
    });
