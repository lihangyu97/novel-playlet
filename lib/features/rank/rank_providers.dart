import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/rank.dart';
import 'rank_cache.dart';

/// 排行榜目录：藏在小说首页 payload 里，整个 App 进程内复用一份。
///
/// 2026-11 起首页不再展示榜单预览（短剧/漫剧的 catalog tab 也没了），
/// 榜单只从推荐页左上角图标进入 [RankPage]；目录仍按上游 payload 解析，
/// 失败由榜单页的错误态 + 重试负责。
final rankCatalogProvider = FutureProvider<RankCatalog>((ref) async {
  final cache = ref.read(rankCatalogCacheProvider);
  final cached = cache.read();
  if (cached != null) return cached;
  final catalog = await ref.read(apiClientProvider).rankCatalog();
  cache.write(catalog);
  return catalog;
});

/// 小说榜在前，短剧榜次之，漫剧榜最后；同组内保持上游目录顺序。
///
/// 排行榜页与首页预取共用：预取默认榜第一页时必须和页面看到的第一顺位一致。
List<RankTab> orderRankTabs(List<RankTab> tabs) {
  int group(RankTab tab) {
    if (tab.genreTab == 2) return 0;
    if (tab.genreTab == 4) return 1;
    if (tab.genreTab == 5) return 2;
    return 3;
  }

  final indexed = tabs.indexed.toList();
  indexed.sort((a, b) {
    final byGroup = group(a.$2).compareTo(group(b.$2));
    return byGroup != 0 ? byGroup : a.$1.compareTo(b.$1);
  });
  return [for (final item in indexed) item.$2];
}
