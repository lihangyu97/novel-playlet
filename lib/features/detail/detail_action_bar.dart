import 'package:flutter/material.dart';

import '../../app/widgets/detail_circle_button.dart';

/// 详情页底部悬浮操作栏：三颗圆形按钮靠右排列，从左到右「收藏 / 缓存 /
/// 播放·阅读」。
///
/// 用 Scaffold.bottomNavigationBar 挂在 body 外面、页面开 `extendBody`，按钮
/// 浮在正文之上；页面末尾按 [totalHeight] 留出滚动空白，最后一行才不会被
/// 按钮永久挡住。
///
/// 按钮只有图标（文案交给 `DetailCircleButton.semanticLabel` 给读屏），三颗
/// 圆等直径、固定间距、靠右对齐，左侧留白给正文呼吸。
class DetailActionBar extends StatelessWidget {
  const DetailActionBar({
    super.key,
    required this.primarySemanticLabel,
    required this.primaryIcon,
    required this.onPrimary,
    required this.shelfSemanticLabel,
    required this.shelfActive,
    required this.onShelf,
    this.offlineButton,
    this.showPrimary = true,
  });

  /// 主操作读屏文案（「开始阅读」「继续阅读 · 第3章」「播放」…）。
  final String primarySemanticLabel;

  /// 主操作图标：小说用书本、短剧用播放键。
  final IconData primaryIcon;

  /// null 表示禁用（没有任何章节可读，且没有 preview 兜底）。
  final VoidCallback? onPrimary;

  /// 左侧「收藏 / 已收藏」读屏文案。
  final String shelfSemanticLabel;

  /// true = 已收藏，点击会取消收藏。
  final bool shelfActive;
  final VoidCallback? onShelf;

  /// 是否显示右侧主操作（播放 / 阅读）。查看详情弹层里只保留收藏 + 缓存。
  final bool showPrimary;

  /// 中间「缓存」入口（`OfflineDownloadButton`）；目录未就绪时为 null。
  ///
  /// 做成注入的 Widget 而不是在本组件里拼 provider：操作栏只负责布局，下载
  /// 状态由详情页自己决定要不要展示。
  final Widget? offlineButton;

  /// 行内左右留白：比正文（16）再收一点，按钮组才像独立浮起来的一层。
  static const double _horizontalGutter = 20;

  /// 圆形之间的固定间距。
  static const double _spacing = 16;

  /// 圆形上方的呼吸留白。
  static const double _paddingTop = 8;

  /// 圆形下方的留白（安全区之外）。
  static const double _paddingBottom = 12;

  /// 悬浮操作栏占用的总高度（圆 + 上下留白 + 底部安全区）。
  ///
  /// 正文从按钮下面穿过，页面末尾要按这个高度留白。
  static double totalHeight(BuildContext context) {
    final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
    const chrome = _paddingTop + _paddingBottom + DetailCircleButton.diameter;
    return chrome + bottomSafe;
  }

  @override
  Widget build(BuildContext context) {
    // 不包 Material / 不做底色：底栏是透明的，三颗圆才是唯一的「实体」。
    // 空白处不拦截手势，正文从按钮之间/下方划过时也能正常滚动。
    return Padding(
      padding: EdgeInsets.only(
        left: _horizontalGutter,
        right: _horizontalGutter,
        top: _paddingTop,
        bottom: _paddingBottom + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        // 靠右对齐：圆组贴着右边留白，左侧空出来给正文。
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DetailCircleButton(
            icon: shelfActive
                ? Icons.bookmark_added_outlined
                : Icons.bookmark_add_outlined,
            semanticLabel: shelfSemanticLabel,
            active: shelfActive,
            onTap: onShelf,
          ),
          // 没有缓存入口时整颗按钮都不占位，但两侧仍保留同一套间距。
          if (offlineButton != null) ...[
            const SizedBox(width: _spacing),
            offlineButton!,
          ],
          if (showPrimary) ...[
            const SizedBox(width: _spacing),
            DetailCircleButton(
              icon: primaryIcon,
              semanticLabel: primarySemanticLabel,
              emphasized: true,
              onTap: onPrimary,
            ),
          ],
        ],
      ),
    );
  }
}
