import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/novel_cover.dart';
import 'mine_relative_time.dart';

/// 「最近阅读 / 最近观看」共用的条目。
///
/// 两侧刻意保持同一版式：封面在左、标题与副标题左对齐、相对时间与右箭头在
/// 最右；小说/短剧面板只镜像页头，不镜像这种列表行，扫视习惯才会一致。
class MineRecentTile extends StatelessWidget {
  const MineRecentTile({
    super.key,
    required this.cover,
    required this.coverAspect,
    required this.title,
    required this.subtitle,
    required this.updatedAt,
    required this.onTap,
  });

  final String cover;

  /// 封面原生比例（高 / 宽）：小说 3:4、短剧 7:10。
  final double coverAspect;
  final String title;
  final String subtitle;
  final DateTime updatedAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            NovelCover(
              url: cover,
              width: 44,
              height: 44 * coverAspect,
              radius: 8,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              mineRelativeTime(updatedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
