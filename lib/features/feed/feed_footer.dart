import 'package:flutter/material.dart';

/// 首页流底部状态：加载下一页 / 失败重试 / 到底了。
///
/// 翻页失败不替换整页，只在列表末尾给一次重试，已加载的卡片保持可读。
class FeedFooter extends StatelessWidget {
  const FeedFooter({
    super.key,
    required this.loadingMore,
    required this.error,
    required this.hasMore,
    required this.onRetry,
    this.retryable = true,
  });

  final bool loadingMore;
  final String? error;
  final bool hasMore;
  final VoidCallback onRetry;

  /// 这次失败是否值得重试：非瞬时失败（badInput / tooLarge / deviceFailed）
  /// 重试同一个请求不会变好，因此不给"重试"按钮（策略来源见 FeedState）。
  final bool retryable;

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
          if (retryable)
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
