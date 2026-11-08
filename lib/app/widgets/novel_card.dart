import 'package:flutter/material.dart';

import '../../data/models/novel_item.dart';
import 'media_card.dart';

/// 推荐页小说分类的卡片：大封面 + 标题 + 作者/分类。
///
/// 推荐流是混排的（榜单、猜你喜欢、新书），这里用统一的三列网格承载；区块
/// 标题与"更多"留给后续按 cell 渲染，卡片本身不感知区块。
///
/// 骨架与短剧卡完全一致，见 [MediaCard]；这里只负责把 [NovelItem] 映射成
/// 卡片的几个文案参数。
class NovelGridCard extends StatelessWidget {
  const NovelGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 108,
    this.heroTag,
    this.showRecommendMeta = false,
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

  @override
  Widget build(BuildContext context) {
    // 作者缺失时退回分类：元信息行不展示空串，但保持占位。
    final head = item.author.isNotEmpty ? item.author : item.category;
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: _metaOf(head),
      width: width,
      onTap: onTap,
      heroTag: heroTag,
    );
  }

  String _metaOf(String head) {
    if (!showRecommendMeta) return head;
    if (item.recommendReason.isNotEmpty) return item.recommendReason;
    if (item.rankScore.isNotEmpty) return item.rankScore;
    final score = scoreLabel(item.score);
    if (score.isEmpty) return head;
    return head.isEmpty ? score : '$head · $score';
  }
}
