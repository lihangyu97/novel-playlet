import 'package:flutter/material.dart';

import '../../../app/widgets/novel_cover.dart';
import '../../../data/models/video_series.dart';

/// 视频列表的卡片：竖版封面 + 标题 + 集数。
///
/// 与小说卡片的区别只在元信息：短剧没有作者，展示「全 N 集」，缺集数时
/// 不硬凑一行（避免出现空字符串占位）。
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
  });

  final VideoSeries item;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverHeight = width * 4 / 3;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NovelCover(url: item.cover, width: width, height: coverHeight),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (item.episodeCount > 0) ...[
              const SizedBox(height: 3),
              Text(
                '全 ${item.episodeCount} 集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
