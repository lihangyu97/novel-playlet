import 'package:flutter/material.dart';

import '../../data/models/novel_item.dart';
import '../theme/app_theme.dart';
import 'novel_cover.dart';

/// 推荐页的卡片：大封面 + 标题 + 作者/分类。
///
/// 推荐流是混排的（榜单、猜你喜欢、新书），这里用统一的三列网格承载；区块
/// 标题与"更多"留给后续按 cell 渲染，卡片本身不感知区块。
class NovelGridCard extends StatelessWidget {
  const NovelGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 108,
  });

  final NovelItem item;
  final VoidCallback onTap;
  final double width;

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
            const SizedBox(height: 3),
            Text(
              item.author.isNotEmpty ? item.author : item.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
