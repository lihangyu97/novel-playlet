import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/rank.dart';
import '../rank/rank_cache.dart';
import '../rank/rank_providers.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_controller.dart';
import '../search/search_providers.dart';

final appPrefetchProvider = Provider<AppPrefetch>((ref) => AppPrefetch(ref));

/// 首页首屏完成后的低优先级预热：搜索页热搜榜 + 推荐页短剧/漫剧首屏 +
/// 排行榜三个内容域首屏。
///
/// 只做数据缓存，不保活页面。失败静默：预热是锦上添花，不能影响首页可用性。
/// 只跑一次/进程；搜索页与排行榜页仍保留自己的按需请求和刷新路径。
class AppPrefetch {
  AppPrefetch(this.ref);

  final Ref ref;
  Future<void>? _warmFuture;

  Future<void> warm() => _warmFuture ??= _warm();

  Future<void> _warm() async {
    // 三组请求互不依赖：一个失败不影响另外两个。
    await Future.wait([
      _warmHotSearch(),
      _warmRankBoards(),
      _warmRecommendFeeds(),
    ]);
  }

  /// 短剧 / 漫剧分类首屏。推荐页默认在小说 tab，用户第一次切过去时
  /// `RecommendFeedController` 还没 build，会先闪加载态；这里提前把 family
  /// 实例建好并拉完第一页，切 tab 时直接命中 AsyncData。
  Future<void> _warmRecommendFeeds() async {
    await Future.wait([
      for (final category in const [
        RecommendCategory.drama,
        RecommendCategory.anime,
      ])
        _warmFeed(category),
    ]);
  }

  Future<void> _warmFeed(RecommendCategory category) async {
    try {
      await ref.read(recommendFeedProvider(category).future);
    } catch (_) {
      // 某个分类失败就保持未加载，用户切过去时按原逻辑重试。
    }
  }

  Future<void> _warmHotSearch() async {
    try {
      await ref.read(hotSearchProvider.notifier).ensureFresh();
    } catch (_) {
      // 热搜只是引导内容，失败保留空榜/旧值。
    }
  }

  Future<void> _warmRankBoards() async {
    try {
      final catalog = await ref.read(rankCatalogProvider.future);
      if (catalog.isEmpty) return;
      final tabs = orderRankTabs(catalog.tabs);
      if (tabs.isEmpty) return;

      // 每个内容域只预热第一顺位榜：小说 / 短剧 / 漫剧各一页，
      // 不把小说的完本/巅峰/新书等 4 个榜也拉一遍。
      final firstByGenre = <int, RankTab>{};
      for (final tab in tabs) {
        firstByGenre.putIfAbsent(tab.genreTab, () => tab);
      }
      await Future.wait([
        for (final tab in firstByGenre.values) _warmBoard(catalog, tab),
      ]);
    } catch (_) {
      // 目录失败就等用户进页面时按需重试。
    }
  }

  Future<void> _warmBoard(RankCatalog catalog, RankTab tab) async {
    try {
      final key = RankBoardCacheKey(
        rankId: catalog.rankId,
        algo: tab.algo,
        genreTab: tab.genreTab,
      );
      final cache = ref.read(rankBoardCacheProvider);
      final existing = cache.read(key);
      if (existing != null && cache.isFresh(existing)) return;

      final board = await ref
          .read(apiClientProvider)
          .rankBoard(
            rankId: catalog.rankId,
            algo: tab.algo,
            genreTab: tab.genreTab,
          );
      cache.write(key, board);
    } catch (_) {
      // 单个内容域失败不影响另外两个；页面打开时仍会按需请求。
    }
  }
}
