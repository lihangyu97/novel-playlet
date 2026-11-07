import 'package:flutter/material.dart';

/// 播放器控制条上的文字选项 chip（倍速 / 清晰度共用）。
///
/// 播放页是黑底视频 + 白色控制条，这个组件故意不走 `colorScheme`：与
/// 控制条现有配色一致，避免在深色视频上出现低对比的 M3 表面色。
class PlayerOptionChip extends StatelessWidget {
  const PlayerOptionChip({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });

  /// chip 上显示的文字（如 `1.5x`、`720P`）。
  final String label;

  final VoidCallback onTap;

  /// 当前是否处于「非默认」状态（如倍速不为 1.0x），给用户一眼可辨的提示。
  final bool active;

  /// 无障碍/长按提示，缺省用 [label]。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final message = tooltip ?? label;
    return Tooltip(
      message: message,
      child: Semantics(
        button: true,
        label: message,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: active ? Colors.black : Colors.white70,
            backgroundColor: active ? Colors.white : Colors.white12,
            minimumSize: const Size(44, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: active ? Colors.white : Colors.white24),
            ),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}
