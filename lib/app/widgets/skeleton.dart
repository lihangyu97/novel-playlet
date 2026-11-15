import 'package:flutter/material.dart';

/// 骨架屏色块的颜色：浅色主题很浅的灰，深色主题略亮一档，和卡片底色区分开。
Color skeletonBlockColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.colorScheme.onSurface.withValues(
    alpha: theme.brightness == Brightness.dark ? 0.14 : 0.07,
  );
}

/// 骨架屏的圆角条（标题/元信息占位）；[radius] 默认取高度一半做胶囊。
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({
    super.key,
    required this.width,
    required this.height,
    this.radius,
  });

  final double width;
  final double height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: skeletonBlockColor(context),
        borderRadius: BorderRadius.circular(radius ?? height / 2),
      ),
    );
  }
}

/// 骨架屏的方块（封面/缩略图占位），默认直角。
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 0,
  });

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: skeletonBlockColor(context),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
