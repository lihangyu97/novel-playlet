import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 底部弹层的统一遮罩色。
///
/// 比 M3 默认的 `black54` 轻一档：弹层本身已经是不透明底，遮罩再重会把
/// 下层页面压成一片黑，看不出「从哪弹出来的」。
const Color appSheetBarrierColor = Color(0x4D000000);

/// 打开一个底部弹层（统一路由参数）。
///
/// 全应用只走这里：透明路由背景（底色和圆角由 [AppBottomSheet] 自己画，
/// 圆角外不会露出 Material 默认白底）+ [appSheetBarrierColor] +
/// 始终 `isScrollControlled`（高弹层可以超过半屏）。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool enableDrag = true,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: appSheetBarrierColor,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    builder: builder,
  );
}

/// 底部弹层的公共骨架：顶部圆角 + 标题区（主标题 / 副标题 / 右上角关闭）+
/// 内容插槽。
///
/// 标题区按「行内元素」排布，等价于 CSS 的 `flex-wrap: wrap`：
///  - 宽度够时主标题和副标题在同一行；
///  - 主标题太长时自己折行（撑满整行）；
///  - 副标题永不折行（`softWrap: false` + 省略号），一行放不下就整块落到
///    下一行、从左边对齐。
/// 实现用 [Wrap]：每个子项先按自身固有宽度参与排布，塞不下的子项自动换行。
///
/// 高度有两种模式：
///  - 传 [heightFactor]（占屏比例）→ 内容区是 `Expanded`，适合滚动列表；
///  - 不传 → 弹层按内容撑高，内容用 `Flexible` 包住，内部滚动视图（比如
///    取色弹层的 `SingleChildScrollView`）在超出可用高度时仍能滚动。
///
/// 内容插槽不自带左右内边距（标题区是 20），需要齐平时由调用方自己加。
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.heightFactor,
    this.backgroundColor,
    this.foregroundColor,
    this.titleStyle,
    this.subtitleStyle,
    this.showClose = true,
    this.closeTooltip = '关闭',
    this.showDivider = true,
  });

  /// 主标题。过长时允许折行。
  final String title;

  /// 副标题（可选）。单行展示，放不下换行到下一行左对齐，不折行。
  final String? subtitle;

  /// 内容插槽。
  final Widget child;

  /// 弹层高度占屏幕的比例；不传则按内容撑高。
  final double? heightFactor;

  /// 底色，默认 `colorScheme.surface`。阅读页按纸色传。
  final Color? backgroundColor;

  /// 前景色（标题/关闭按钮/分割线都从它派生），默认 `colorScheme.onSurface`。
  final Color? foregroundColor;

  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  /// 是否在右上角显示关闭按钮。
  final bool showClose;

  final String closeTooltip;

  /// 标题区下方是否画一条发丝分割线。
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final background = backgroundColor ?? theme.colorScheme.surface;
    final foreground = foregroundColor ?? theme.colorScheme.onSurface;
    final effectiveTitleStyle =
        titleStyle ??
        theme.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: foreground,
        );
    final effectiveSubtitleStyle =
        subtitleStyle ??
        theme.textTheme.bodySmall?.copyWith(
          height: 1.3,
          color: foreground.withValues(alpha: 0.55),
        );

    final sheet = Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.sheetRadius),
        ),
      ),
      // 弹层底色一直铺到屏幕底：把 Home 指示条的高度做成容器内部留白，
      // 而不是交给外层 SafeArea，否则最底部会露出一条弹层外的透明带。
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: heightFactor == null
            ? MainAxisSize.min
            : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(
            title: title,
            subtitle: subtitle,
            titleStyle: effectiveTitleStyle,
            subtitleStyle: effectiveSubtitleStyle,
            foreground: foreground,
            showClose: showClose,
            closeTooltip: closeTooltip,
          ),
          if (showDivider)
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: foreground.withValues(alpha: 0.08),
            ),
          heightFactor == null
              ? Flexible(child: child)
              : Expanded(child: child),
        ],
      ),
    );

    if (heightFactor == null) return sheet;
    return FractionallySizedBox(heightFactor: heightFactor, child: sheet);
  }
}

/// 标题区：主标题 + 副标题（行内排布，可折行）+ 右上角关闭。
class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
    required this.foreground,
    required this.showClose,
    required this.closeTooltip,
  });

  final String title;
  final String? subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final Color foreground;
  final bool showClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    return Padding(
      // 右侧 8 是给 IconButton 自身的内边距让位，让关闭按钮的视觉边距也是 20。
      padding: EdgeInsets.fromLTRB(20, 16, showClose ? 8 : 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(title, style: titleStyle),
                if (hasSubtitle)
                  Text(
                    subtitle!,
                    // 副标题不折行：放不下就整体换到下一行左对齐。
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleStyle,
                  ),
              ],
            ),
          ),
          if (showClose)
            IconButton(
              tooltip: closeTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              color: foreground.withValues(alpha: 0.7),
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}
