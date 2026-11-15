import 'package:flutter/material.dart';

/// 行内「失败 + 重试」：加载失败时占一小块，不替换整页内容。
///
/// 搜索结果分区、首页流底部翻页失败、阅读页切章失败提示条共用同一套排版：
/// 图标 + 最多两行说明 + 「重试」文本按钮（可选「关闭」）。
class InlineErrorRow extends StatelessWidget {
  const InlineErrorRow({
    super.key,
    required this.message,
    this.icon = Icons.error_outline_rounded,
    this.onRetry,
    this.onDismiss,
    this.foreground,
    this.background,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.messageMaxLines = 2,
  });

  final String message;
  final IconData icon;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  /// 前景色；null = `colorScheme.onSurface`。阅读页按纸色传。
  final Color? foreground;

  /// 底色；null = 透明（搜索结果行 / 列表底部）。阅读页提示条传淡色底 + 圆角。
  final Color? background;

  final EdgeInsetsGeometry padding;
  final int messageMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = foreground ?? theme.colorScheme.onSurface;
    final row = Row(
      children: [
        Icon(icon, size: 16, color: fg.withValues(alpha: 0.7)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: messageMaxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              color: fg.withValues(alpha: 0.8),
            ),
          ),
        ),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: const Text('重试'),
          ),
        if (onDismiss != null)
          IconButton(
            onPressed: onDismiss,
            tooltip: '关闭',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: fg.withValues(alpha: 0.6),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
    final child = background == null
        ? row
        : Container(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(14),
            ),
            child: row,
          );
    return Padding(padding: padding, child: child);
  }
}
