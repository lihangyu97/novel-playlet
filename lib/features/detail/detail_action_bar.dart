import 'package:flutter/material.dart';

import '../../app/widgets/detail_icon_label_button.dart';

/// 详情页底部悬浮操作栏：三颗圆形按钮，从左到右「收藏 / 缓存 / 播放·阅读」。
///
/// 用 Scaffold.bottomNavigationBar 挂在 body 外面、页面开 `extendBody`，按钮
/// 浮在正文之上；页面末尾按 [totalHeight] 留出滚动空白，最后一行才不会被
/// 按钮永久挡住。
///
/// 三颗按钮平分整行（`Expanded`），圆形直径一致、顶部对齐：屏幕变窄时只有
/// 下方文案会折行，三颗圆的水平间距仍然均等，主按钮不会因为文案更长被挤偏。
class DetailActionBar extends StatelessWidget {
  const DetailActionBar({
    super.key,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    required this.shelfLabel,
    required this.shelfActive,
    required this.onShelf,
    this.offlineButton,
  });

  /// 主操作文案（「开始阅读」「继续阅读 · 第 3 章」「播放」…）。
  final String primaryLabel;

  /// 主操作图标：小说用书本、短剧用播放键。
  final IconData primaryIcon;

  /// null 表示禁用（没有任何章节可读，且没有 preview 兜底）。
  final VoidCallback? onPrimary;

  /// 左侧「收藏 / 已收藏」文案。
  final String shelfLabel;

  /// true = 已收藏，点击会取消收藏。
  final bool shelfActive;
  final VoidCallback? onShelf;

  /// 中间「缓存」入口（`OfflineDownloadButton`）；目录未就绪时为 null。
  ///
  /// 做成注入的 Widget 而不是在本组件里拼 provider：操作栏只负责布局，下载
  /// 状态由详情页自己决定要不要展示。
  final Widget? offlineButton;

  /// 行内左右留白：比正文（16）再收一点，按钮组才像独立浮起来的一层；
  /// 三颗圆等分剩余宽度，间距天然一致。
  static const double _horizontalGutter = 20;

  /// 圆形上方的呼吸留白。
  static const double _paddingTop = 8;

  /// 圆形下方的留白（安全区之外）。
  static const double _paddingBottom = 10;

  /// 圆形本体高度：直径 + 与文案的间距。
  static const double _buttonHeight =
      DetailIconLabelButton.diameter + DetailIconLabelButton.labelGap;

  /// 悬浮操作栏占用的总高度（圆 + 文案 + 上下留白 + 底部安全区）。
  ///
  /// 正文从按钮下面穿过，页面末尾要按这个高度留白。文案按
  /// [DetailIconLabelButton.labelMaxLines] 两行计算：宁可多留一点空白，也不让
  /// 大字模式下最后一行被按钮盖住。
  static double totalHeight(BuildContext context) {
    final bottomSafe = MediaQuery.viewPaddingOf(context).bottom;
    const chrome = _paddingTop + _paddingBottom + _buttonHeight;
    return chrome + DetailIconLabelButton.maxLabelHeight + bottomSafe;
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
        // 三颗圆顶部对齐；文案折行只会向下长，不会把圆往下拽。
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DetailIconLabelButton(
              icon: shelfActive
                  ? Icons.bookmark_added_outlined
                  : Icons.bookmark_add_outlined,
              label: shelfLabel,
              active: shelfActive,
              onTap: onShelf,
            ),
          ),
          // 没有缓存入口时保留等宽空槽：另外两颗按钮的位置不会左右跳。
          Expanded(child: offlineButton ?? const SizedBox.shrink()),
          Expanded(
            child: DetailIconLabelButton(
              icon: primaryIcon,
              label: primaryLabel,
              emphasized: true,
              onTap: onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
