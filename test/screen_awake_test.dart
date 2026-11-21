import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/screen_awake.dart';

/// 屏幕常亮通道：只负责把 bool 送到原生，失败静默（不影响播放）。
void main() {
  const channel = MethodChannel(PlatformScreenAwakeController.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('把 set 的布尔参数原样送到原生', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });

    const controller = PlatformScreenAwakeController();
    await controller.setKeepAwake(true);
    await controller.setKeepAwake(false);

    expect(calls.map((call) => call.method), ['set', 'set']);
    expect(calls.map((call) => call.arguments), [true, false]);
  });

  testWidgets('通道失败不抛给播放页', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });

    await expectLater(
      const PlatformScreenAwakeController().setKeepAwake(true),
      completes,
    );
  });
}
