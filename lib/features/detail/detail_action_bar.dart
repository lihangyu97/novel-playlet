import 'package:flutter/material.dart';

import '../../app/widgets/detail_icon_label_button.dart';
import 'detail_style.dart';

/// 底部固定操作栏：左「收藏/已收藏」、中间主按钮「开始阅读 / 继续阅读」、
/// 右「缓存/缓存中/已缓存」，三颗按钮统一成「上图标、下文字」的线条风格。
///
/// 用 Scaffold.bottomNavigationBar 挂在 body 外面，滚动时始终可见；
/// 传入 null 回调即按钮禁用（数据未就绪）。左右两侧等宽（见
/// [DetailIconLabelButton.width]），主按钮因此天然居中，不会被挤偏。
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

  /// 左侧「收藏 / 已收藏」文案。
  final String shelfLabel;

  /// true = 已收藏，点击会取消收藏。
  final bool shelfActive;
  final VoidCallback? onShelf;

  /// 右侧「缓存」入口（[OfflineDownloadButton]）；目录未就绪时为 null。
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
                DetailIconLabelButton(
                  icon: shelfActive
                      ? Icons.bookmark_added_outlined
                      : Icons.bookmark_add_outlined,
                  label: shelfLabel,
                  active: shelfActive,
                  onTap: onShelf,
                ),
                const SizedBox(width: 8),
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
                const SizedBox(width: 8),
                // 没有缓存入口时留同宽空位：左右对称，主按钮仍然居中。
                offlineButton ??
                    const SizedBox(width: DetailIconLabelButton.width),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
