import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../recommend/recommend_item.dart';
import '../video/widgets/video_card.dart';

/// 一条搜索结果卡片：小说走 [NovelGridCard]、短剧/漫剧走 [VideoCard]。
///
/// 搜索页的横滑行和「查看全部」结果页共用这一张卡：两处只是宽度与字号不同
/// （行内按 `CompactCardRow` 缩一档、结果页用瀑布流的自然宽度），卡片字段
/// 口径必须一致——搜索响应里的推荐理由是「漫剧 / 上新」这类分类角标，一律
/// 不展示，只留「全 N 集 + 热度」；季角标由 [VideoCard] 从标题解析。
class SearchResultCard extends StatelessWidget {
  const SearchResultCard({
    super.key,
    required this.item,
    required this.width,
    required this.heroSource,
    required this.onTap,
    this.naturalTitleHeight = false,
  });

  final RecommendItem item;
  final double width;

  /// Hero tag 的来源维度（页面-分类）。同一本书/同一部剧会同时出现在搜索页
  /// 与「查看全部」页，tag 必须带来源，否则两个路由里的 Hero 会撞 tag。
  final String heroSource;

  final VoidCallback onTap;

  /// 标题按内容自然高度（1~2 行）。瀑布流里开启，行内固定两行保持同一排对齐。
  final bool naturalTitleHeight;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      NovelRecommendItem(:final novel) => NovelGridCard(
        key: ValueKey('search-novel-${novel.id}'),
        item: novel,
        width: width,
        onTap: onTap,
        heroTag: CoverHeroTag.novel(heroSource, novel.id),
        showRecommendMeta: true,
        coverAspect: kNovelCoverAspect,
        surface: true,
        naturalTitleHeight: naturalTitleHeight,
      ),
      VideoRecommendItem(:final video) => VideoCard(
        key: ValueKey('search-video-${video.id}'),
        item: video,
        width: width,
        onTap: onTap,
        heroTag: CoverHeroTag.video(heroSource, video.id),
        showRecommendMeta: true,
        // 搜索卡不展示推荐理由：这个字段（`recommend_reason_list` 第一条）在
        // 搜索响应里不是分类名（「漫剧」）就是「上新」这类角标，和卡片上的
        // 集数/热度重复且挤占窄卡；只留「全 N 集 + 热度」。
        showReason: false,
        coverAspect: kVideoCoverAspect,
        surface: true,
        naturalTitleHeight: naturalTitleHeight,
      ),
    };
  }
}

/// 打开一条搜索结果：小说进详情，短剧/漫剧进剧集详情。
///
/// 与 [SearchResultCard] 的 `heroSource` 必须一致，封面才能接住飞入动画。
void openSearchResult(
  BuildContext context,
  RecommendItem item, {
  required String heroSource,
}) {
  switch (item) {
    case NovelRecommendItem(:final novel):
      context.pushAppRoute(
        DetailRoute(
          bookId: novel.id,
          preview: novel,
          heroTag: CoverHeroTag.novel(heroSource, novel.id),
        ),
      );
    case VideoRecommendItem(:final video):
      context.pushAppRoute(
        VideoDetailRoute(
          seriesId: video.id,
          preview: video,
          heroTag: CoverHeroTag.video(heroSource, video.id),
        ),
      );
  }
}
