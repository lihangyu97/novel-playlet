import 'package:flutter/material.dart';

/// 小标签 pill：详情页题材标签、搜索历史词、榜单条目标签共用。
///
/// 一套观感：胶囊圆角、`surfaceContainerHighest` 底、`bodySmall` 灰字；传
/// [onTap] 时包一层可点的水波纹（搜索历史），否则是纯展示（标签）。
class AppPill extends StatelessWidget {
  const AppPill({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(99),
        ),
        child: text,
      );
    }
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(99),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: text,
        ),
      ),
    );
  }
}
