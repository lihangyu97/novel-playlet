import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/player_system_status.dart';

/// 平台通道返回值的映射：网络类型 → 顶栏文案；任何读不到的字段都要降级
/// 成 null，不能影响播放页其它 UI。
void main() {
  const channel = MethodChannel(PlayerSystemStatusReader.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<PlayerSystemStatus> read(Map<String, Object?> payload) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'read');
          return payload;
        });
    return const PlayerSystemStatusReader().read();
  }

  testWidgets('WiFi / 5G / 无 radio / 离线 的映射', (tester) async {
    var status = await read({'batteryPercent': 86, 'networkType': 'wifi'});
    expect(status.batteryPercent, 86);
    expect(status.networkLabel, 'WiFi');

    status = await read({'networkType': 'cellular', 'radio': '5G'});
    expect(status.networkLabel, '5G');

    status = await read({'networkType': 'cellular', 'radio': '4G'});
    expect(status.networkLabel, '4G');

    // 没有 READ_PHONE_STATE / 没有服务时降级成「蜂窝」。
    status = await read({'networkType': 'cellular'});
    expect(status.networkLabel, '蜂窝');

    status = await read({'networkType': 'none'});
    expect(status.networkLabel, isNull);
    expect(status.batteryPercent, isNull);
  });

  testWidgets('电量越界或通道失败时降级为 null', (tester) async {
    var status = await read({
      'batteryPercent': 140,
      'networkType': 'cellular',
      'radio': '4G',
    });
    expect(status.batteryPercent, isNull);
    expect(status.networkLabel, '4G');

    // 平台通道失败（老包 / 通道未注册）不能抛，整组降级为 null。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });
    status = await const PlayerSystemStatusReader().read();
    expect(status.batteryPercent, isNull);
    expect(status.networkLabel, isNull);
  });
}
