import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../rank/rank_cache.dart';
import '../rank/rank_providers.dart';
import '../search/search_providers.dart';

final appPrefetchProvider = Provider<AppPrefetch>((ref) => AppPrefetch(ref));

/// 首页首屏完成后的低优先级预热：搜索页热搜榜 + 排行榜默认榜第一页。
///
/// 只做数据缓存，不保活页面。失败静默：预热是锦上添花，不能影响首页可用性。
/// 只跑一次/进程；搜索页与排行榜页仍保留自己的按需请求和刷新路径。
class AppPrefetch {
  AppPrefetch(this.ref);

  final Ref ref;
  Future<void>? _warmFuture;

  Future<void> warm() => _warmFuture ??= _warm();

  Future<void> _warm() async {
    // 两个请求互不依赖：一个失败不影响另一个。
    await Future.wait([_warmHotSearch(), _warmRankBoard()]);
  }

  Future<void> _warmHotSearch() async {
    try {
      await ref.read(hotSearchProvider.notifier).ensureFresh();
    } catch (_) {
      // 热搜只是引导内容，失败保留空榜/旧值。
    }
  }

  Future<void> _warmRankBoard() async {
    try {
      final catalog = await ref.read(rankCatalogProvider.future);
      if (catalog.isEmpty) return;
      final tabs = orderRankTabs(catalog.tabs);
      if (tabs.isEmpty) return;
      // 只预热页面默认落地的第一顺位榜，不拉 6 个榜。
      final tab = tabs.first;
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
      // 榜单目录/第一页失败就等用户进页面时按需重试。
    }
  }
}
