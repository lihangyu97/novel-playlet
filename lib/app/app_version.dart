import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前安装包的版本信息：展示版本（iOS `CFBundleShortVersionString` /
/// Android `versionName`）与构建号（`CFBundleVersion` / `versionCode`）。
///
/// 由原生侧从安装包元数据读取（`pubspec.yaml` 的 `version: x.y.z+n` 打包时
/// 写进包内），所以显示的一定是「当前这个包」的版本——不依赖生成文件或
/// `--dart-define`，debug / profile / release 都一致。
@immutable
class AppVersion {
  const AppVersion({required this.name, required this.build});

  final String name;
  final String build;

  bool get isKnown => name.isNotEmpty;

  /// 「1.0.0 (15)」；构建号缺失时只显示版本名。
  String get label => build.isEmpty ? name : '$name ($build)';

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.name == name && other.build == build;

  @override
  int get hashCode => Object.hash(name, build);
}

/// 构建渠道：beta 包由 `scripts/build_ios_app.sh --flavor beta` 通过
/// `--dart-define=APP_FLAVOR=beta` 标记，其余（含 release / debug）按 Release。
const String appFlavor = String.fromEnvironment(
  'APP_FLAVOR',
  defaultValue: 'release',
);

/// 构建渠道 → 版本脚注前缀（`Beta` / `Release`）。
String appFlavorLabelFor(String flavor) =>
    flavor.trim().toLowerCase() == 'beta' ? 'Beta' : 'Release';

/// 设置页版本脚注的前缀：`Beta` / `Release`。
String get appFlavorLabel => appFlavorLabelFor(appFlavor);

/// 版本方法通道；改通道名/方法名要同步改
/// `ios/Runner/AppDelegate.swift` 与 `android/.../MainActivity.kt`。
const MethodChannel appVersionChannel = MethodChannel(
  'novel_playlet/app_version',
);

/// 读不到原生实现时返回 null（桌面/测试环境没有这个方法通道），设置页据此
/// 隐藏版本脚注，而不是显示 "dev" 或空括号。
final appVersionProvider = FutureProvider<AppVersion?>((ref) async {
  try {
    final map = await appVersionChannel.invokeMapMethod<String, Object?>('get');
    final name = (map?['versionName'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    final build = (map?['buildNumber'] as String?)?.trim() ?? '';
    return AppVersion(name: name, build: build);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
});
