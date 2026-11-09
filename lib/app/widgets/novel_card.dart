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
    this.coverAspect = kCoverAspect,
    this.surface = false,
    this.naturalTitleHeight = false,
  });

  final NovelItem item;
  final VoidCallback onTap;
  final double width;

  /// 封面 Hero tag；null = 不参与飞入动画（例如深链/无列表来源）。
  final String? heroTag;

  /// 元信息行是否按推荐流规则展示（推荐流开启；书架等入口保持原名，避免
  /// 同一张卡片在不同页面展示规则不一致）。
  ///
  /// 优先级：`recommend_reason_list` 第一条 → `rank_score`（热度）→
  /// 「作者 · 评分」；都没有时退回作者/分类（原行为）。
  final bool showRecommendMeta;

  /// 封面高 / 宽；推荐流传 [kNovelCoverAspect]，其它入口保持默认。
  final double coverAspect;

  /// 是否画成白底卡片（见 [MediaCard.surface]）。
  final bool surface;

  /// 标题是否按内容自然高度（见 [MediaCard.naturalTitleHeight]）。
  final bool naturalTitleHeight;

  @override
  Widget build(BuildContext context) {
    // 作者缺失时退回分类：元信息行不展示空串，但保持占位。
    final head = item.author.isNotEmpty ? item.author : item.category;
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: _metaOf(head),
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

  /// 元信息行：推荐理由 → 热度 → 作者/分类；评分开到封面角标，不再占这一行。
  String _metaOf(String head) {
    if (!showRecommendMeta) return head;
    if (item.recommendReason.isNotEmpty) return item.recommendReason;
    if (item.rankScore.isNotEmpty) return item.rankScore;
    return head;
  }
}
