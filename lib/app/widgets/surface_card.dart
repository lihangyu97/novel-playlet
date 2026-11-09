import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 通用「白底卡片」容器：底色 + 小圆角 + 可选点击 + 裁剪。
///
/// 推荐流先接入（封面满宽出血、卡片纯白底、封面下方直角）；后续其它列表想
/// 逐步换成卡片化时直接复用本组件，不要再各写一层 `Container` / `Material`。
///
/// 为什么用 [Material] 而不是 `Container`：孩子（封面图）要按卡片圆角裁切，
/// `Material` 自带 `clipBehavior` + `borderRadius`，`InkWell` 也必须有
/// Material 祖先。注意水波纹画在 Material 的 ink 层、封面图会把它盖住，
/// 实际只在文字区可见；要在封面上也有按压反馈得换 `Ink`/`Ink.image`，本期不做。
///
/// 暗色不画阴影：深色底上阴影几乎不可见，靠比画布亮一档的底色分层更干净。
class AppSurfaceCard extends StatelessWidget {
  const AppSurfaceCard({
    super.key,
    required this.child,
    this.onTap,
    this.radius = AppTheme.mediaCardRadius,
    this.color,
  });

  final Widget child;

  /// 点击回调；null = 不可点（不包 InkWell）。
  final VoidCallback? onTap;

  final double radius;

  /// 底色；null = 走 [AppTheme.mediaCardColor]（浅色白 / 暗色 surfaceContainerHigh）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return Material(
      color: color ?? AppTheme.mediaCardColor(context),
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? child
          : InkWell(onTap: onTap, borderRadius: borderRadius, child: child),
    );
  }
}
