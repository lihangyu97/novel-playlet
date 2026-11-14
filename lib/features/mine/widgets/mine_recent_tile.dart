import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/novel_cover.dart';
import 'mine_relative_time.dart';

/// 「最近阅读 / 最近观看」共用的条目。
///
/// 小说/短剧两个 tab 刻意保持同一版式：封面在左、标题与副标题左对齐、相对
/// 时间与右箭头在最右，扫视习惯一致；只有副标题的进度文案不同。
///
/// 封面裁成正方形，边长取「标题 + 间距 + 副标题」的高度：两行文字和封面
/// 等高，条目更紧凑，也不会因为小说/短剧原生封面比例不同而一高一低。
class MineRecentTile extends StatelessWidget {
  const MineRecentTile({
    super.key,
    required this.cover,
    required this.title,
    required this.subtitle,
    required this.updatedAt,
    required this.onTap,
  });

  final String cover;

  /// 标题与副标题之间的间距；封面边长计算也用它。
  static const double _titleGap = 5;

  /// 封面圆角：比卡片封面小一档，只做轻微收边。
  static const double _coverRadius = 6;
  final String title;
  final String subtitle;
  final DateTime updatedAt;
  final VoidCallback onTap;

  /// 正方形封面边长 = 标题行高 + 间距 + 副标题行高。
  ///
  /// 行高按主题字号 × `TextStyle.height` 推算，跟随系统字号缩放；这样封面
  /// 始终和右侧两行文字的视觉高度一致，而不是写死一个固定尺寸。
  double _coverSize(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = theme.textTheme.titleSmall;
    final subtitleStyle = theme.textTheme.bodySmall;
    final titleLine =
        scaler.scale(titleStyle?.fontSize ?? 14) * (titleStyle?.height ?? 1.4);
    final subtitleLine =
        scaler.scale(subtitleStyle?.fontSize ?? 12) *
        (subtitleStyle?.height ?? 1.4);
    return titleLine + _titleGap + subtitleLine;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final coverSize = _coverSize(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            NovelCover(
              url: cover,
              width: coverSize,
              height: coverSize,
              radius: _coverRadius,
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
                  const SizedBox(height: _titleGap),
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
