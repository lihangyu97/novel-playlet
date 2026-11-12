import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/app_version.dart';

/// 版本信息来自原生包元数据：这里用 mock 方法通道模拟 iOS/Android 侧返回，
/// 锁住「读值 / 解析 / 缺省」三段，避免设置页脚注在真机上显示空版本。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(appVersionChannel, null);
  });

  ProviderContainer containerWithVersion() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('从原生读出版本名与构建号，label 拼接为「版本 (构建号)」', () async {
    messenger.setMockMethodCallHandler(appVersionChannel, (call) async {
      expect(call.method, 'get');
      return {'versionName': '1.0.0', 'buildNumber': '15'};
    });

    final version = await containerWithVersion().read(
      appVersionProvider.future,
    );
    expect(version, const AppVersion(name: '1.0.0', build: '15'));
    expect(version!.label, '1.0.0 (15)');
  });

  test('原生没有实现（桌面/测试环境）时返回 null，页面不显示脚注', () async {
    // 不设 handler：invokeMapMethod 会抛 MissingPluginException。
    final version = await containerWithVersion().read(
      appVersionProvider.future,
    );
    expect(version, isNull);
  });

  test('原生返回空版本名时按读不到处理', () async {
    messenger.setMockMethodCallHandler(
      appVersionChannel,
      (call) async => {'versionName': '', 'buildNumber': '15'},
    );
    expect(
      await containerWithVersion().read(appVersionProvider.future),
      isNull,
    );
  });

  test('构建号缺失时 label 只显示版本名', () async {
    messenger.setMockMethodCallHandler(
      appVersionChannel,
      (call) async => {'versionName': '1.0.0', 'buildNumber': ''},
    );
    final version = await containerWithVersion().read(
      appVersionProvider.future,
    );
    expect(version!.label, '1.0.0');
  });
}
