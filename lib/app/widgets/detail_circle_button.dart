import 'package:flutter/material.dart';

/// 详情页底部悬浮操作的圆形按钮：只有图标，没有可见文字。
///
/// 为什么不用 [FloatingActionButton]：三个入口要共用同一套尺寸、状态色与禁用
/// 态，用圆形 [Material] + [InkWell] 自己拼更好控制。
///
/// 状态（收藏 / 已收藏、缓存中 / 已缓存）靠图标与配色表达；提示文案放在
/// [semanticLabel] 里交给读屏，不再占用按钮下方的版面。
class DetailCircleButton extends StatelessWidget {
  const DetailCircleButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    this.active = false,
    this.emphasized = false,
  });

  /// 圆形直径。三颗按钮同尺寸，横向才「对齐」。
  static const double diameter = 54;

  final IconData icon;

  /// 读屏播报的文案（「收藏 / 已收藏」「缓存中」这类状态说明）。
  final String semanticLabel;

  /// null = 禁用（与主操作一致：数据未就绪时整排都点不动）。
  final VoidCallback? onTap;

  /// true 时用主色底/主色图标，表示「已收藏 / 缓存中 / 已缓存」这类状态。
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
    if (!enabled) {
      background = scheme.surfaceContainerHigh.withValues(alpha: 0.56);
      iconColor = scheme.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (emphasized) {
      background = scheme.primary;
      iconColor = scheme.onPrimary;
    } else if (active) {
      // 有状态时用实色底：直接把 14% 主色压到按钮的常态底色上。外观与原来的
      // 半透明一致，但不再透出下面的封面/正文，避免看起来「发灰、变透明」。
      background = Color.alphaBlend(
        scheme.primary.withValues(alpha: 0.14),
        scheme.surfaceContainerHigh,
      );
      iconColor = scheme.primary;
    } else {
      background = scheme.surfaceContainerHigh;
      iconColor = scheme.onSurface;
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      // 图标只是视觉表达，动作与文案都交给这一层，读屏用户双击才点得动
      // （圆形里的 InkWell 语义被排除掉了）。
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox(
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
    );
  }
}
