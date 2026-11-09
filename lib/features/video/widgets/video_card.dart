import 'package:flutter/material.dart';

import '../../../app/widgets/media_card.dart';
import '../../../app/widgets/novel_cover.dart';
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
    this.coverAspect = kCoverAspect,
    this.surface = false,
    this.naturalTitleHeight = false,
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

  /// 封面高 / 宽；推荐流传 [kVideoCoverAspect]，其它入口保持默认。
  final double coverAspect;

  /// 是否画成白底卡片（见 [MediaCard.surface]）。
  final bool surface;

  /// 标题是否按内容自然高度（见 [MediaCard.naturalTitleHeight]）。
  final bool naturalTitleHeight;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: _metaOf(),
      // 评分和小说一致：移到封面右上角角标，不占元信息行。
      cornerText: showRecommendMeta ? scoreLabel(item.score) : null,
      width: width,
      onTap: onTap,
      heroTag: heroTag,
      coverAspect: coverAspect,
      surface: surface,
      naturalTitleHeight: naturalTitleHeight,
    );
  }

  /// 元信息行 =「全 N 集」+ 推荐理由 / 热度（集数永远最前）。
  String? _metaOf() {
    final episodes = item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : '';
    if (!showRecommendMeta) return episodes.isEmpty ? null : episodes;
    final tail = <String>[
      if (item.recommendReason.isNotEmpty)
        item.recommendReason
      else if (item.rankScore.isNotEmpty)
        item.rankScore,
    ];
    final parts = [if (episodes.isNotEmpty) episodes, ...tail];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
