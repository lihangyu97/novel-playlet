import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/playback_speed.dart';
import 'package:novel_playlet/features/video/widgets/playback_speed_menu.dart';
import 'package:novel_playlet/features/video/widgets/player_bar_text.dart';
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

    testWidgets('倍速文字显示当前值并响应点击', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: PlayerBarText(
                label: '1.5x',
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

    testWidgets('点 chip 弹出倍速小浮窗：竖排列全档位，点一档回调并自动关闭', (tester) async {
      double? picked;
      final openStates = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: PlaybackSpeedButton(
                current: 1.0,
                onSelected: (speed) => picked = speed,
                onOpenChanged: openStates.add,
              ),
            ),
          ),
        ),
      );

      // 收起时只有 chip 自己那一个 1.0x，没有浮窗。
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.byKey(speedOptionKey(1.5)), findsNothing);

      await tester.tap(find.byTooltip('播放速度'));
      await tester.pumpAndSettle();

      // 浮窗里是竖排的一列倍速（不再有底部弹层的标题和说明文案）。
      for (final speed in playbackSpeeds) {
        expect(find.byKey(speedOptionKey(speed)), findsOneWidget);
      }
      expect(find.textContaining('更耗电'), findsNothing, reason: '浮窗里不放说明文案');
      expect(openStates, [true], reason: '打开要通知页面冻结自动隐藏');

      await tester.tap(find.byKey(speedOptionKey(1.5)));
      await tester.pumpAndSettle();
      expect(picked, 1.5);
      expect(find.byKey(speedOptionKey(1.5)), findsNothing, reason: '选完即关');
      expect(openStates, [true, false]);
    });

    testWidgets('浮窗够小：贴着 chip 右沿，控制条贴底时自动翻到上方', (tester) async {
      // 还原播放页的真实位置：chip 在屏幕右下角。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: PlaybackSpeedButton(current: 1.0, onSelected: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('播放速度'));
      await tester.pumpAndSettle();

      final chip = tester.getRect(find.byTooltip('播放速度'));
      final first = tester.getRect(
        find.byKey(speedOptionKey(playbackSpeeds.first)),
      );
      final last = tester.getRect(
        find.byKey(speedOptionKey(playbackSpeeds.last)),
      );

      expect(
        last.bottom,
        lessThanOrEqualTo(chip.top),
        reason: '下面放不下就翻到 chip 上方',
      );
      expect(last.bottom - first.top, lessThan(200), reason: '五档排下来仍是一块小浮窗');
      expect(first.height, lessThan(40), reason: '行高比 M3 默认 48 矮');
      expect(first.width, lessThan(160), reason: '只放短文案，横向不该拉满屏');
    });
  });
}
