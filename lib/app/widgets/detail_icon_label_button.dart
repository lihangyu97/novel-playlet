import 'package:flutter/material.dart';

/// 详情页底栏的「上图标、下文字」按钮（收藏 / 缓存共用，保证风格一致）。
///
/// 为什么不用 [IconButton] + tooltip：用户希望收藏与缓存两个入口都直接显示
/// 文字（「收藏」「缓存中」…），且图标与文字上下排布；tooltip 只在长按/悬浮时
/// 才出现，移动端基本不可见。用 [Semantics.label] 保留无障碍语义。
///
/// 固定 [width] 让左右两个按钮等宽，中间主按钮自然居中；[active] 用主题色 +
/// 加粗区分「已收藏」「已缓存」这类有状态的样子。
class DetailIconLabelButton extends StatelessWidget {
  const DetailIconLabelButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  /// 按钮固定宽度（px）。左右两侧同一个宽度，主按钮才会在视觉上居中。
  static const double width = 58;

  /// 固定高度：与主按钮（FilledButton）接近，图标 + 文字不会把底栏撑高。
  static const double height = 46;

  final IconData icon;
  final String label;

  /// null = 禁用（与主按钮一致：数据未就绪时整排都点不动）。
  final VoidCallback? onTap;

  /// true 时图标/文字用主题色 + 加粗，表示「已收藏 / 已缓存」等已完成状态。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final Color color;
    if (!enabled) {
      color = scheme.onSurfaceVariant.withValues(alpha: 0.38);
    } else if (active) {
      color = scheme.primary;
    } else {
      color = scheme.onSurfaceVariant;
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      // 文字已经由 label 提供给读屏，避免重复播报一遍 Text。
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        height: height,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  height: 1.1,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
