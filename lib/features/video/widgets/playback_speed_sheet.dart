import 'package:flutter/material.dart';

import '../../../app/widgets/app_bottom_sheet.dart';
import '../playback_speed.dart';

/// 打开「播放速度」底部弹层，返回选中的倍速（取消返回 null）。
///
/// 与选集弹层同款交互：底部弹层 + 选中态按钮；页面拿到值后只写 provider，
/// 由页面统一把倍速下发给当前 controller。
Future<double?> showPlaybackSpeedSheet(
  BuildContext context, {
  required double current,
}) {
  return showAppBottomSheet<double>(
    context: context,
    builder: (_) => _PlaybackSpeedSheet(current: current),
  );
}

class _PlaybackSpeedSheet extends StatelessWidget {
  const _PlaybackSpeedSheet({required this.current});

  final double current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBottomSheet(
      title: '播放速度',
      closeTooltip: '关闭播放速度',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '倍速会跨集保持；3x 更耗电，个别片源可能略有卡顿',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final speed in playbackSpeeds) ...[
                  if (speed != playbackSpeeds.first) const SizedBox(width: 8),
                  Expanded(
                    child: _SpeedButton(
                      speed: speed,
                      selected: speed == current,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.selected});

  final double speed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final label = Text(playbackSpeedLabel(speed));
    void onTap() => Navigator.of(context).pop(speed);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    // 选中态复用选集弹层的 FilledButton / OutlinedButton 组合，视觉一致。
    return selected
        ? FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 44),
              shape: shape,
            ),
            child: label,
          )
        : OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 44),
              shape: shape,
            ),
            child: label,
          );
  }
}
