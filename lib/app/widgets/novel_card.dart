import 'package:flutter/material.dart';

import '../../data/models/novel_item.dart';
import 'media_card.dart';
import 'novel_cover.dart';

/// 推荐页小说分类的卡片：封面 + 标题 + 作者/分类。
///
/// 推荐流用白底瀑布流卡片（[surface] + [naturalTitleHeight] + 原生封面比例）；
/// 书架等固定网格沿用紧凑形态。骨架见 [MediaCard]，这里只负责把
/// [NovelItem] 映射成卡片的几个文案参数。
class NovelGridCard extends StatelessWidget {
  const NovelGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 108,
    this.heroTag,
    this.showRecommendMeta = false,
    this.reasonOnCover = false,
    this.coverAspect = kCoverAspect,
    this.surface = false,
    this.naturalTitleHeight = false,
    this.fallbackToCategory = true,
  });

  final NovelItem item;
  final VoidCallback onTap;
  final double width;

  /// 封面 Hero tag；null = 不参与飞入动画（例如深链/无列表来源）。
  final String? heroTag;

  /// 元信息是否按推荐流规则展示（推荐流开启；书架等入口保持原名，避免
  /// 同一张卡片在不同页面展示规则不一致）。
  ///
  /// 书名下方**固定一行作者**（作者空退回分类）；推荐流再把
  /// `recommend_reason_list` 第一条与 `rank_score`（热度）**有就显示**。
  /// 具体摆放由 [reasonOnCover] 决定。
  final bool showRecommendMeta;

  /// 推荐理由是否放封面左上角角标（`recommend_reason_list` 第一条）。
  ///
  /// 双列卡片够宽时开启：理由上封面、热度右对齐到作者同一行，文字区只留
  /// 标题 + 一行元信息。三列卡片太窄，角标放不下，退回文字区独立一行。
  final bool reasonOnCover;

  /// 封面高 / 宽；推荐流传 [kNovelCoverAspect]，其它入口保持默认。
  final double coverAspect;

  /// 是否画成白底卡片（见 [MediaCard.surface]）。
  final bool surface;

  /// 标题是否按内容自然高度（见 [MediaCard.naturalTitleHeight]）。
  final bool naturalTitleHeight;

  /// 作者为空时是否退回展示分类。
  ///
  /// 推荐流/搜索结果需要分类兜底；我的页书架只要求「书名 + 作者」，作者缺失
  /// 时宁可留空也不拿分类顶替，所以传 false。
  final bool fallbackToCategory;

  @override
  Widget build(BuildContext context) {
    // 作者始终占元信息行；作者缺失时按入口决定是否退回分类（两者都空则
    // 不占行，白底卡片形态下空元信息不产生额外高度）。
    final head = item.author.isNotEmpty
        ? item.author
        : (fallbackToCategory ? item.category : '');
    final reason = showRecommendMeta ? item.recommendReason : '';
    final heat = showRecommendMeta ? item.rankScore : '';
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: head,
      // 双列：理由上封面角标、热度右对齐到作者行尾。
      coverBadge: reasonOnCover ? reason : null,
      metaTrailing: reasonOnCover ? heat : null,
      // 三列：理由/热度各自一行，有就显示；书架等入口不传。
      extraMeta: showRecommendMeta && !reasonOnCover
          ? [if (reason.isNotEmpty) reason, if (heat.isNotEmpty) heat]
          : const [],
      // 封面占位色用上游主色（`color_dominate`），加载过程不闪灰块。
      coverPlaceholderColor: coverPlaceholderColorOf(item.colorDominate),
      // 评分从作者行拿出来，单独放封面右上角角标（白字 + 半透明底）。
      cornerText: showRecommendMeta ? scoreLabel(item.score) : null,
      width: width,
      onTap: onTap,
      heroTag: heroTag,
      coverAspect: coverAspect,
      surface: surface,
      naturalTitleHeight: naturalTitleHeight,
    );
  }
}
