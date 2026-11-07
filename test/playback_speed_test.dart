import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/playback_speed.dart';
import 'package:novel_playlet/features/video/widgets/playback_speed_sheet.dart';
import 'package:novel_playlet/features/video/widgets/player_option_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('倍速偏好', () {
    test('默认 1.0x，白名单外的值被忽略', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(playbackSpeedProvider), 1.0);

      final notifier = container.read(playbackSpeedProvider.notifier);
      notifier.setSpeed(1.5);
      expect(container.read(playbackSpeedProvider), 1.5);

      notifier.setSpeed(0.75);
      notifier.setSpeed(-1);
      notifier.setSpeed(4);
      expect(
        container.read(playbackSpeedProvider),
        1.5,
        reason: '只接受 playbackSpeeds 白名单里的值',
      );
    });

    test('改速落盘，新容器能从偏好恢复', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(playbackSpeedProvider.notifier).setSpeed(2.0);
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(PlaybackSpeedController.prefsKey), 2.0);

      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      expect(restored.read(playbackSpeedProvider), 1.0, reason: '首帧先用默认值');
      await pumpEventQueue();
      expect(restored.read(playbackSpeedProvider), 2.0);
    });

    test('落盘值不在白名单时忽略，保持默认 1.0x', () async {
      SharedPreferences.setMockInitialValues({
        PlaybackSpeedController.prefsKey: 9.9,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await pumpEventQueue();
      expect(container.read(playbackSpeedProvider), 1.0);
    });
  });

  group('倍速 UI', () {
    test('文案保留一位小数：1.0x / 1.25x / 3.0x', () {
      expect(playbackSpeedLabel(1.0), '1.0x');
      expect(playbackSpeedLabel(1.25), '1.25x');
      expect(playbackSpeedLabel(1.5), '1.5x');
      expect(playbackSpeedLabel(2.0), '2.0x');
      expect(playbackSpeedLabel(3.0), '3.0x');
    });

    testWidgets('倍速 chip 显示当前值并响应点击', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: PlayerOptionChip(
                label: '1.5x',
                active: true,
                tooltip: '播放速度',
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('1.5x'), findsOneWidget);
      await tester.tap(find.text('1.5x'));
      expect(taps, 1);
    });

    testWidgets('弹层列出 1.0–3.0x，点选返回新倍速', (tester) async {
      double? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    picked = await showPlaybackSpeedSheet(
                      context,
                      current: 1.0,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('播放速度'), findsOneWidget);
      for (final speed in playbackSpeeds) {
        expect(find.text(playbackSpeedLabel(speed)), findsOneWidget);
      }

      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(picked, 1.5);
      expect(find.text('播放速度'), findsNothing);
    });
  });
}
