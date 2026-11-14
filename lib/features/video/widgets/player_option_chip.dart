import 'package:flutter/material.dart';

/// 播放器控制条上的文字选项 chip（倍速 / 清晰度共用）。
///
/// 播放页是黑底视频 + 白色控制条，这个组件故意不走 `colorScheme`：与
/// 控制条现有配色一致，避免在深色视频上出现低对比的 M3 表面色。
class PlayerOptionChip extends StatelessWidget {
  const PlayerOptionChip({
    super.key,
    required this.label,
    this.onTap,
    this.active = false,
    this.tooltip,
  });

  /// chip 上显示的文字（如 `1.5x`、`720P`）。
  final String label;

  /// null = 仅展示（如当前清晰度），不响应点击。
  final VoidCallback? onTap;

  /// 当前是否处于「非默认」状态（如倍速不为 1.0x），给用户一眼可辨的提示。
  final bool active;

  /// 无障碍/长按提示，缺省用 [label]。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final message = tooltip ?? label;
    final foreground = active ? Colors.black : Colors.white70;
    final background = active ? Colors.white : Colors.white12;
    final border = BorderSide(color: active ? Colors.white : Colors.white24);
    final style = TextButton.styleFrom(
      foregroundColor: foreground,
      backgroundColor: background,
      minimumSize: const Size(44, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: border,
      ),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );

    if (onTap == null) {
      // 只展示：保持和可点 chip 一样的外观，但不给点击反馈。
      return Tooltip(
        message: message,
        child: Semantics(
          label: message,
          child: Container(
            constraints: const BoxConstraints(minHeight: 28, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: Border.fromBorderSide(border),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: message,
      child: Semantics(
        button: true,
        label: message,
        child: TextButton(onPressed: onTap, style: style, child: Text(label)),
      ),
    );
  }
}
