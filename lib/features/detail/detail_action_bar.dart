import 'package:flutter/material.dart';

import 'detail_style.dart';

/// 底部固定操作栏：左侧书架切换，右侧主按钮「开始阅读 / 继续阅读」。
///
/// 用 Scaffold.bottomNavigationBar 挂在 body 外面，滚动时始终可见；
/// 传入 null 回调即按钮禁用（数据未就绪）。
class DetailActionBar extends StatelessWidget {
  const DetailActionBar({
    super.key,
    required this.primaryLabel,
    required this.onPrimary,
    required this.shelfLabel,
    required this.shelfActive,
    required this.onShelf,
    this.offlineButton,
  });

  final String primaryLabel;

  /// null 表示禁用（没有任何章节可读，且没有 preview 兜底）。
  final VoidCallback? onPrimary;
  final String shelfLabel;

  /// true = 已在书架，点击会移出。
  final bool shelfActive;
  final VoidCallback? onShelf;

  /// 「缓存整本」入口（[OfflineDownloadButton]）；目录未就绪时为 null。
  ///
  /// 做成注入的 Widget 而不是在本组件里拼 provider：操作栏只负责布局，下载
  /// 状态由详情页自己决定要不要展示。
  final Widget? offlineButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              detailGutter,
              10,
              detailGutter,
              12,
            ),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onShelf,
                  icon: Icon(
                    shelfActive
                        ? Icons.check_rounded
                        : Icons.bookmark_add_outlined,
                    size: 18,
                  ),
                  label: Text(
                    shelfLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    foregroundColor: shelfActive
                        ? scheme.primary
                        : scheme.onSurface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                if (offlineButton != null) ...[
                  const SizedBox(width: 4),
                  offlineButton!,
                ],
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: onPrimary,
                    child: Text(
                      primaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
