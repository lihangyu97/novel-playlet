import 'package:flutter/material.dart';

/// 区块标题：左侧标题 + 右侧统计，跟着内容一起滚走。
class RecommendSectionTitle extends StatelessWidget {
  const RecommendSectionTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 列表底部状态：加载下一页 / 失败重试 / 到底了。
///
/// 翻页失败不替换整页，只在列表末尾给一次重试，已加载的卡片保持可读。
class RecommendFooter extends StatelessWidget {
  const RecommendFooter({
    super.key,
    required this.loadingMore,
    required this.error,
    required this.hasMore,
    required this.onRetry,
  });

  final bool loadingMore;
  final String? error;
  final bool hasMore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final error = this.error;

    Widget child;
    if (loadingMore) {
      child = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (error != null) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, textAlign: TextAlign.center, style: mutedStyle),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      );
    } else if (!hasMore) {
      child = Text('没有更多了', style: mutedStyle);
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Center(child: child),
    );
  }
}
