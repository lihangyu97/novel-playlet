import 'package:flutter/material.dart';

/// 「推荐」页搜索框下方的一级分类。
///
/// [tabType] 是书城首页接口的 `tab_type`（见 docs/bookmall-tabs.md）：
/// 2 = 小说推荐、8 = 短剧、24 = 漫剧。小说的首页流目前固定走
/// `ApiClient.recommend()`（书籍推荐 2），视频类分类才把 [tabType] 传给
/// `ApiClient.videoFeed()`；以后若要按分类请求书籍流，从这里的 [tabType] 取。
///
/// 搜索走另一条接口，`tab_type` 语义也不同（3 = 书籍、11 = 短剧、8 = 漫画），
/// 所以单独放 [searchTabType]。上游没有「漫剧」搜索 tab，漫剧暂借漫画 tab 8。
enum RecommendCategory {
  novel(
    label: '小说',
    tabType: 2,
    searchTabType: 3,
    searchHint: '搜索书名/作者',
    emptyIcon: Icons.auto_stories_outlined,
  ),
  drama(
    label: '短剧',
    tabType: 8,
    searchTabType: 11,
    searchHint: '搜索短剧',
    emptyIcon: Icons.movie_outlined,
  ),
  anime(
    label: '漫剧',
    tabType: 24,
    searchTabType: 11,
    searchHint: '搜索漫剧',
    emptyIcon: Icons.auto_awesome_motion_outlined,
    fallbackQuery: '漫剧',
  );

  const RecommendCategory({
    required this.label,
    required this.tabType,
    required this.searchTabType,
    required this.searchHint,
    required this.emptyIcon,
    this.fallbackQuery,
  });

  final String label;
  final int tabType;
  final int searchTabType;
  final String searchHint;
  final IconData emptyIcon;

  /// 首页流游标耗尽后，翻页兜底用的搜索关键词（目前只有漫剧需要）。
  /// 见 [RecommendCategory.usesManjuSearch]。
  final String? fallbackQuery;

  /// 小说卡片和短剧/漫剧卡片的字段、详情页都不同，只有小说走书籍详情。
  bool get isNovel => this == RecommendCategory.novel;

  /// 漫剧首页流（`tab_type=24`）没有游标，搜索/翻页都要借短剧搜索 tab 再按
  /// 漫剧元数据过滤（见 `ApiClient.manjuSearch`）。
  bool get usesManjuSearch => this == RecommendCategory.anime;
}
