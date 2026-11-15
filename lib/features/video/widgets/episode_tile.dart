import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// 选集里的「集数」按钮：短剧详情的内嵌选集和播放页的选集弹层共用。
///
/// 视觉约定（两处必须一致）：**不描边**，未选中只给一层很淡的底色，选中用
/// 主色填充 + 主色上的文字；只显示集数（1000+ 集的剧不写「第 x 集」）。
/// 尺寸由调用方按所在容器传（详情页 34 高、弹层 44 高），样式只在这里维护。
class EpisodeTile extends StatelessWidget {
  const EpisodeTile({
    super.key,
    required this.index,
    required this.onTap,
    this.selected = false,
    this.height = 44,
    this.radius = 10,
    this.fontSize = 14,
  });

  /// 整部剧里的 0 基下标，显示时 +1。
  final int index;
  final VoidCallback onTap;
  final bool selected;

  /// 按钮高度（决定点击热区）。
  final double height;

  /// 圆角。
  final double radius;

  /// 集数字号。
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        // 高度必须由 minimumSize 决定：compact 视觉密度会把最小高度再压 8pt，
        // 详情页（Wrap 不给高度）就会比播放页（Grid 固定 44）矮一截。
        minimumSize: Size(0, height),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // 无描边：未选中靠淡底色区分，选中是主色实心。
        backgroundColor: selected
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        foregroundColor: selected ? scheme.onPrimary : scheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: TextStyle(
          fontSize: fontSize,
          fontWeight: selected
              ? context.appWeight(FontWeight.w700)
              : context.appWeight(FontWeight.w500),
        ),
      ),
      child: Text('${index + 1}', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
