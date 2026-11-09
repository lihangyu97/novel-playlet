import 'package:flutter/material.dart';

/// 页头：标题 + 图标 + 一行统计 + 设置入口。
///
/// [mirrored] 为 true 时整行左右镜像（短剧）：设置按钮在左、标题与图标在右、
/// 统计文字右对齐，和小说侧形成对称。
class MineHeader extends StatelessWidget {
  const MineHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.stats,
    this.mirrored = false,
  });

  final String title;
  final IconData icon;
  final String stats;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleText = Text(
      title,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    );
    final iconBox = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 19, color: scheme.primary),
    );
    // 设置按钮由页面统一画在 Stack 顶层（切换时在屏幕内左右滑动），这里只留
    // 同宽的占位，保证两侧页头高度与文字位置不因移除按钮而变化。
    const settingsPlaceholder = SizedBox(width: 40, height: 40);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 4),
      child: Column(
        crossAxisAlignment: mirrored
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            children: mirrored
                ? [
                    settingsPlaceholder,
                    const Spacer(),
                    titleText,
                    const SizedBox(width: 10),
                    iconBox,
                  ]
                : [
                    iconBox,
                    const SizedBox(width: 10),
                    titleText,
                    const Spacer(),
                    settingsPlaceholder,
                  ],
          ),
          const SizedBox(height: 8),
          Text(
            stats,
            textAlign: mirrored ? TextAlign.right : TextAlign.left,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块标题（我的书架 / 最近阅读 / 最近观看 / 我的收藏）。
class MineSectionHeader extends StatelessWidget {
  const MineSectionHeader({
    super.key,
    required this.title,
    this.hint,
    this.mirrored = false,
  });

  final String title;
  final String? hint;
  final bool mirrored;

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
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 10),
      child: Row(
        children: mirrored
            ? [
                if (hintText != null) ...[hintText, const SizedBox(width: 8)],
                const Spacer(),
                titleText,
              ]
            : [
                Expanded(child: titleText),
                if (hintText != null) ...[const SizedBox(width: 8), hintText],
              ],
      ),
    );
  }
}
