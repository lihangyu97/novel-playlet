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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NovelCover(url: item.cover, width: width, height: width * 1.38),
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

/// 搜索结果的横向条目：封面 + 标题 + 作者/分类 + 简介两行。
class NovelListTile extends StatelessWidget {
  const NovelListTile({super.key, required this.item, required this.onTap});

  final NovelItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (item.author.isNotEmpty) item.author,
      if (item.category.isNotEmpty) item.category,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NovelCover(url: item.cover, width: 66, height: 90),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (item.intro.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.4,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.9,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
