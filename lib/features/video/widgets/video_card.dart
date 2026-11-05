import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/cover_hero.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../data/models/video_series.dart';

/// 视频列表的卡片：竖版封面 + 标题 + 集数。
///
/// 与小说卡片的区别只在元信息：短剧/漫剧没有作者，展示「全 N 集」，缺集数
/// 时不硬凑一行（避免出现空字符串占位）。封面比例、圆角、字号与小说卡
/// 完全一致（都走 [kCoverAspect] / [AppTheme.cardRadius]），推荐页切分类
/// 时卡片尺寸不变。
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
    final theme = Theme.of(context);
    final coverHeight = width * kCoverAspect;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverHero(
              tag: heroTag,
              child: NovelCover(
                url: item.cover,
                width: width,
                height: coverHeight,
              ),
            ),
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
