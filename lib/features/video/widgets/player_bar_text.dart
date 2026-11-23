import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// 播放器控制条上的纯文字选项（选集 / 详情 / 评论 / 相关 / 清晰度 / 倍速）。
///
/// 底栏除了播放/暂停，统一用「和第 N 集一样」的文案样式：13pt、w500、白色，
/// 不画 chip 底色/边框，也不再有倍速的白底高亮——选中态只靠数字本身表达。
/// 点击区仍按 40×40 收，和原来的图标按钮一致，窄屏不会点不准。
///
/// 播放页是黑底视频 + 白色控制条，故意不走 `colorScheme`，避免在深色视频上
/// 出现低对比的 M3 表面色。
class PlayerBarText extends StatelessWidget {
  const PlayerBarText({
    super.key,
    required this.label,
    this.onTap,
    this.tooltip,
    this.muted = false,
  });

  /// 文案（如 `第 3 集`、`详情`、`1.5x`）。
  final String label;

  /// null = 仅展示（如当前清晰度），不响应点击。
  final VoidCallback? onTap;

  /// 无障碍/长按提示，缺省用 [label]。
  final String? tooltip;

  /// 只读信息（清晰度）用略淡的白色，仍与可点项同一套字号。
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final message = tooltip ?? label;
    final style = TextStyle(
      fontSize: 13,
      fontWeight: context.appWeight(FontWeight.w500),
      color: muted ? Colors.white70 : Colors.white,
    );
    final text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );

    if (onTap == null) {
      // 只展示：和可点击项保持同样的最小点击区高度，底栏基线不会错位。
      return Tooltip(
        message: message,
        child: Semantics(
          label: message,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: text,
          ),
        ),
      );
    }

    return Tooltip(
      message: message,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: style,
        ),
        child: text,
      ),
    );
  }
}
