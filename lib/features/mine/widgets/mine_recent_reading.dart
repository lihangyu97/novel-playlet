import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../core/storage/reading_store.dart';

/// 最近阅读区：封面 + 书名 + 读到第几章 + 相对时间，点击直接续读。
///
/// 与书架不同，这里的每一条都是可续读的进度记录，所以点击目标是阅读页
/// 而不是详情页（省掉"进详情再找章"的一步）。
class MineRecentReading extends StatelessWidget {
  const MineRecentReading({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<ReadingProgress> items;
  final ValueChanged<ReadingProgress> onOpen;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.separated(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final progress = items[index];
          return _RecentReadingTile(
            progress: progress,
            onTap: () => onOpen(progress),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(height: 2),
      ),
    );
  }
}

class _RecentReadingTile extends StatelessWidget {
  const _RecentReadingTile({required this.progress, required this.onTap});

  final ReadingProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = progress.bookTitle.isEmpty ? '未命名作品' : progress.bookTitle;
    final chapter = progress.chapterId.isEmpty
        ? '尚未开始阅读'
        : '读到第 ${progress.chapterIndex + 1} 章';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            NovelCover(
              url: progress.cover,
              width: 44,
              height: 44 * kCoverAspect,
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
                    chapter,
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
              _relativeTime(progress.updatedAt),
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

/// 相对时间只做粗粒度提示：最近阅读的时间精确到秒没有意义，反而制造噪音。
String _relativeTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(time.year, time.month, time.day)).inDays;
  if (days == 1) return '昨天';
  if (days < 7) return '$days 天前';
  if (time.year == now.year) return '${time.month} 月 ${time.day} 日';
  return '${time.year} 年 ${time.month} 月 ${time.day} 日';
}
