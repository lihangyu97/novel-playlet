import 'package:flutter/material.dart';

/// 圆形色块：主题预设色、自定义色、阅读底色、取色器预览共用。
///
/// 选中态统一「外圈描边 + 打勾」（[showCheck] 可关掉，自定义色块用图标占位）；
/// 勾/图标颜色默认按背景亮暗自动选，读不清时可以显式传 [iconColor]。
/// 传 [onTap] 才是可点控件（包 InkResponse + 读屏语义），不传就是纯展示。
class ColorSwatchDot extends StatelessWidget {
  const ColorSwatchDot({
    super.key,
    required this.color,
    this.size = 44,
    this.selected = false,
    this.onTap,
    this.icon,
    this.showCheck = true,
    this.tooltip,
    this.semanticLabel,
    this.ringColor,
    this.iconColor,
    this.unselectedBorder,
    this.unselectedBorderWidth = 1,
  });

  final Color color;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  /// 常驻图标（自定义色块画调色盘）；null = 只在选中时画勾。
  final IconData? icon;

  /// 选中时是否画勾。
  final bool showCheck;

  final String? tooltip;

  /// 读屏文案；null = 用 [tooltip]。
  final String? semanticLabel;

  /// 选中描边色；null = `colorScheme.onSurface`。
  final Color? ringColor;

  /// 图标/勾的颜色；null = 按背景亮暗自动取黑/白。
  final Color? iconColor;

  /// 未选中时的描边（浅色块压在白底上需要一条细边）；null = 不描边。
  final Color? unselectedBorder;
  final double unselectedBorderWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final autoColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.light
        ? Colors.black54
        : Colors.white70;
    final foreground = iconColor ?? autoColor;
    final iconData =
        icon ?? (selected && showCheck ? Icons.check_rounded : null);

    Widget dot = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: selected
            ? Border.all(color: ringColor ?? scheme.onSurface, width: 2)
            : unselectedBorder == null
            ? null
            : Border.all(
                color: unselectedBorder!,
                width: unselectedBorderWidth,
              ),
      ),
      child: iconData == null
          ? null
          : Icon(iconData, size: size * 0.42, color: foreground),
    );

    final onTap = this.onTap;
    if (onTap != null) {
      dot = InkResponse(onTap: onTap, radius: size * 0.68, child: dot);
    }
    final label = semanticLabel ?? tooltip;
    if (label != null) {
      dot = Tooltip(
        message: tooltip ?? label,
        child: Semantics(
          button: onTap != null,
          selected: selected,
          label: label,
          child: dot,
        ),
      );
    }
    return dot;
  }
}
