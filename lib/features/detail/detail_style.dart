import 'package:flutter/material.dart';

/// 页面左右留白。卡片、目录行、底部操作栏共用，保证竖线对齐。
const double detailGutter = 16;

/// 区块标题行：左边标题，右边可选操作（如「共 N 章 · 查看全部」）。
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      detailGutter,
      detailGutter,
      detailGutter,
      4,
    ),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // trailing 靠右但不抢占固定宽度：窄屏/大字号下让它自己省略，
          // 而不是把标题挤没。
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// 标签小圆角 pill。Material 的 [Chip] 自带 48dp 点击区，一屏标签会撑出
/// 一大块空白，这里只画视觉（标签本身不可点）。
class DetailTagChip extends StatelessWidget {
  const DetailTagChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
