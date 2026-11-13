import 'package:flutter/material.dart';

/// 详情页底部悬浮操作按钮：圆形底 + 下方文字（收藏 / 缓存 / 播放·阅读共用）。
///
/// 为什么不用 [FloatingActionButton]：三个入口都要用文字表达状态（「已收藏」
/// 「缓存中」「继续观看 · 第 4 集」），FAB 只承载图标；用圆形 [Material] +
/// [InkWell] 自己拼，图标、文字与状态色才能一起对齐。
///
/// 文字放在圆形外面而不是塞进圆里：`继续阅读 · 第 3 章` 这类文案塞不进 54pt
/// 的圆，硬塞只能截断，用户就看不出「续读第几章」。文字区单独响应点击，
/// 点圆和点文字都能触发同一个操作。
class DetailIconLabelButton extends StatelessWidget {
  const DetailIconLabelButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.emphasized = false,
  });

  /// 圆形直径。三颗按钮同尺寸，横向才「对齐」。
  static const double diameter = 54;

  /// 圆形与文字的间距。
  static const double labelGap = 6;

  /// 文字字号/行高：与详情页其它小字（labelSmall 11）同一档。
  static const double labelFontSize = 11;
  static const double labelLineHeight = 1.2;

  /// 文案最多两行。窄屏上「继续观看 · 第 4 集」会折行，详情页按两行给
  /// 滚动内容留白（见 `DetailActionBar.totalHeight`），最后一行不会被盖住。
  static const int labelMaxLines = 2;

  /// 文字最大缩放：与悬浮底栏（`FloatingNavigationBar`）保持一致，极端
  /// 字号下也不至于把三颗按钮撑成三行高。
  static const double maxTextScale = 1.3;

  /// 文案在 [labelMaxLines] 行、[maxTextScale] 上限下的最大高度（px）。
  ///
  /// 详情页据此给滚动内容留出底部空白；实际只有一行时底部会多留一点空，
  /// 宁可多留，也不让大字模式下最后一行被按钮盖住。
  static const double maxLabelHeight =
      labelFontSize * labelLineHeight * labelMaxLines * maxTextScale;

  final IconData icon;
  final String label;

  /// null = 禁用（与主操作一致：数据未就绪时整排都点不动）。
  final VoidCallback? onTap;

  /// true 时用主色底/主色文字，表示「已收藏 / 缓存中 / 已缓存」这类状态。
  final bool active;

  /// true = 主操作（播放 / 阅读）：实心主色圆，视觉权重最高。
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;

    final Color background;
    final Color iconColor;
    final Color labelColor;
    if (!enabled) {
      background = scheme.surfaceContainerHigh.withValues(alpha: 0.56);
      iconColor = scheme.onSurfaceVariant.withValues(alpha: 0.38);
      labelColor = scheme.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (emphasized) {
      background = scheme.primary;
      iconColor = scheme.onPrimary;
      labelColor = scheme.primary;
    } else if (active) {
      background = scheme.primary.withValues(alpha: 0.14);
      iconColor = scheme.primary;
      labelColor = scheme.primary;
    } else {
      background = scheme.surfaceContainerHigh;
      iconColor = scheme.onSurface;
      labelColor = scheme.onSurfaceVariant;
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      // 文字已经由 label 提供给读屏，避免重复播报一遍 Text；动作也交给
      // 这一层，读屏用户双击才点得动（圆形里的 InkWell 语义被排除掉了）。
      onTap: onTap,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: diameter,
            height: diameter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: background,
                // 圆形按钮没有底栏托底，只靠投影和画布分层；禁用态不投影，
                // 免得「点不动」的东西看起来比能点的还突出。
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: scheme.shadow.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? 0.45
                                : 0.14,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ]
                    : null,
              ),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  customBorder: const CircleBorder(),
                  child: Center(child: Icon(icon, size: 24, color: iconColor)),
                ),
              ),
            ),
          ),
          const SizedBox(height: labelGap),
          GestureDetector(
            // 点文字也要能触发，且不跟圆形里的 InkWell 抢手势：文字区是
            // 独立的一块，命中谁就由谁处理。
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: maxTextScale,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: labelMaxLines,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: labelFontSize,
                  height: labelLineHeight,
                  color: labelColor,
                  fontWeight: emphasized || active
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
