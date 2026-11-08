import 'package:flutter/material.dart';

import '../../../app/widgets/media_card.dart';
import '../../../data/models/video_series.dart';

/// 视频列表的卡片：竖版封面 + 标题 + 集数。
///
/// 与小说卡片的区别只在元信息：短剧/漫剧没有作者，展示「全 N 集」，缺集数
/// 时不硬凑一行（避免出现空字符串占位）。骨架见 [MediaCard]。
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
    this.heroTag,
    this.showRecommendMeta = false,
  });

  final VideoSeries item;
  final double width;
  final VoidCallback onTap;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String? heroTag;

  /// 元信息行是否按推荐流规则展示（推荐流开启；书架等入口保持「全 N 集」）。
  ///
  /// 文案 =「全 N 集」+ 现有推荐元信息：`recommend_reason_list` 第一条 →
  /// 热度（短剧用 `rec_text`）→ 评分；集数始终在最前面。
  final bool showRecommendMeta;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: _metaOf(),
      width: width,
      onTap: onTap,
      heroTag: heroTag,
    );
  }

  String? _metaOf() {
    final episodes = item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : '';
    if (!showRecommendMeta) return episodes.isEmpty ? null : episodes;
    // 集数永远排最前（短剧卡片的固有信息），后面再接推荐理由 / 热度 / 评分。
    final tail = <String>[
      if (item.recommendReason.isNotEmpty)
        item.recommendReason
      else if (item.rankScore.isNotEmpty)
        item.rankScore
      else if (scoreLabel(item.score).isNotEmpty)
        scoreLabel(item.score),
    ];
    final parts = [if (episodes.isNotEmpty) episodes, ...tail];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
