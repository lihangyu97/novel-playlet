import 'package:flutter/material.dart';

import '../playback_speed.dart';
import 'player_option_chip.dart';

/// 播放页的倍速入口：点 chip 贴着它弹出一列倍速（M3 menu），点一档即关。
///
/// 原来是底部弹层：遮掉大半屏画面，还要「打开弹层 → 再点一档」两步。控制条
/// 本来就贴着屏幕下沿，用贴着 chip 展开的小浮窗更轻，也和缓存中心右上角
/// 三个点的溢出菜单是同一套视觉。
///
/// 选项就是 [playbackSpeeds] 那一份，不额外写解释文案（「3x 更耗电」这类
/// 说明在设置文档里，不放播放器浮窗里）；行高压到 40，五档加起来仍是一块
/// 小浮窗。
class PlaybackSpeedButton extends StatelessWidget {
  const PlaybackSpeedButton({
    super.key,
    required this.current,
    required this.onSelected,
    this.onOpenChanged,
  });

  /// 当前倍速：决定 chip 文案、是否高亮，以及菜单里哪一档打勾。
  final double current;

  /// 选中某一档后回调（菜单此时已自动关闭）。
  final ValueChanged<double> onSelected;

  /// 浮窗开/关通知：页面用它在浮窗打开期间冻结控制条的自动隐藏，
  /// 否则选到一半控制条连同 chip 一起淡出。
  final ValueChanged<bool>? onOpenChanged;

  /// 一档倍速的行：M3 默认 48，这里压到 40（compact 后实际 32），五档排下来
  /// 仍是一块小浮窗，又没小到点不准。
  static final ButtonStyle _itemStyle = MenuItemButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      // 贴着 chip 展开：默认往下（对齐 chip 右沿），控制条贴底放不下时
      // MenuAnchor 自动翻到 chip 上方；6pt 是翻上去之后与 chip 的间距。
      alignmentOffset: const Offset(0, 6),
      onOpen: () => onOpenChanged?.call(true),
      onClose: () => onOpenChanged?.call(false),
      style: const MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        // 只放「1.25x」这类短文案：收窄到 88，避免默认弹层那样的整块空白。
        minimumSize: WidgetStatePropertyAll(Size(88, 0)),
      ),
      menuChildren: [
        for (final speed in playbackSpeeds)
          MenuItemButton(
            key: speedOptionKey(speed),
            style: _itemStyle,
            onPressed: () => onSelected(speed),
            leadingIcon: speed == current
                ? const Icon(Icons.check_rounded, size: 16)
                : const SizedBox(width: 16),
            child: Text(playbackSpeedLabel(speed)),
          ),
      ],
      builder: (context, controller, _) => PlayerOptionChip(
        label: playbackSpeedLabel(current),
        active: current != 1.0,
        tooltip: '播放速度',
        onTap: controller.isOpen ? controller.close : controller.open,
      ),
    );
  }
}

/// 菜单里某一档倍速的 key（测试用它点选，不依赖 chip 上同时出现的文案）。
Key speedOptionKey(double speed) =>
    ValueKey('playback-speed-${playbackSpeedLabel(speed)}');
