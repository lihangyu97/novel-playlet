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
  });

  final VideoSeries item;
  final double width;
  final VoidCallback onTap;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : null,
      width: width,
      onTap: onTap,
      heroTag: heroTag,
    );
  }
}
