import 'package:flutter/material.dart';

/// 我的页页头：图标 + 主标题 + 一行合并统计 + 设置入口。
///
/// 小说/短剧两个 tab 共用**同一个**页头（固定贴顶、不随内容滚动），不再按
/// 内容类型做镜像版式；设置入口只有右上角这一枚。
class MineHeader extends StatelessWidget {
  const MineHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.stats,
    required this.onSettings,
  });

  final String title;
  final IconData icon;

  /// 两个 tab 合并后的一行统计，例如「书架 12 本 · 收藏 4 部」。
  final String stats;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 19, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onSettings,
                tooltip: '设置',
                visualDensity: VisualDensity.compact,
                iconSize: 22,
                color: scheme.onSurfaceVariant,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stats,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块标题（最近阅读 / 最近观看 / 我的书架 / 我的收藏）。
///
/// 小说/短剧两个 tab 的版式已经统一为左对齐，不再有镜像参数。
class MineSectionHeader extends StatelessWidget {
  const MineSectionHeader({super.key, required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final hintText = hint == null
        ? null
        : Text(
            hint!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
    return Padding(
      // 区块标题上下也统一 8（与左右留白一致）。
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          Expanded(child: titleText),
          if (hintText != null) ...[const SizedBox(width: 8), hintText],
        ],
      ),
    );
  }
}
