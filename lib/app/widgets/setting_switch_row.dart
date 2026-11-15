import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 设置项里的一行开关：左侧标题 + 说明，右侧 [Switch]。
///
/// 设置页（跟随系统深色）与阅读设置弹层（对话高亮 / 段评气泡）共用。阅读弹层
/// 按纸色传 [foreground] / [muted]，设置页不传就走主题色。
class SettingSwitchRow extends StatelessWidget {
  const SettingSwitchRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.foreground,
    this.muted,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// 标题色；null = `colorScheme.onSurface`。
  final Color? foreground;

  /// 说明文字色；null = `colorScheme.onSurfaceVariant`。
  final Color? muted;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground ?? scheme.onSurface,
                    fontWeight: context.appWeight(FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted ?? scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
