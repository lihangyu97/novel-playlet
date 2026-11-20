import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 横屏全屏顶栏右上角要展示的系统状态：电量 + 当前网络。
///
/// 时间不走平台通道（本地 `DateTime.now()`，按分钟刷新）；电量和网络类型
/// 只能问原生，见 [PlayerSystemStatusReader]。
@immutable
class PlayerSystemStatus {
  const PlayerSystemStatus({this.batteryPercent, this.networkLabel});

  /// 0–100。读不到（模拟器 / 通道失败）时为 null，界面上不展示这一项。
  final int? batteryPercent;

  /// `WiFi` / `5G` / `4G` / `3G` / `2G` / `蜂窝` / `有线`。读不到时为 null。
  final String? networkLabel;

  @override
  bool operator ==(Object other) =>
      other is PlayerSystemStatus &&
      other.batteryPercent == batteryPercent &&
      other.networkLabel == networkLabel;

  @override
  int get hashCode => Object.hash(batteryPercent, networkLabel);
}

/// 读系统电量与当前网络类型。
///
/// 不引第三方电量/网络插件：4G/5G 的区分本来就要原生 API（iOS 的
/// `CTTelephonyNetworkInfo`、Android 的 `TelephonyManager`），插件也只到
/// 「cellular」这一层；这个页面又只要两项信息，一个 MethodChannel 更轻。
///
/// 通道约定（iOS `ios/Runner/AppDelegate.swift`、Android `MainActivity.kt`
/// 两端必须一致）：
///   method: read
///   result: {
///     batteryPercent: Int?,            // 0–100
///     networkType: "wifi" | "cellular" | "wired" | "none" | "unknown",
///     radio: String?                   // cellular 时: "5G" / "4G" / "3G" / "2G"
///   }
class PlayerSystemStatusReader {
  const PlayerSystemStatusReader();

  static const channelName = 'novel_playlet/system_status';
  static const _channel = MethodChannel(channelName);

  /// 失败永远返回空状态（只显示时间），不能因为读电量把播放页弄挂。
  Future<PlayerSystemStatus> read() async {
    try {
      final data = await _channel.invokeMapMethod<String, Object?>('read');
      if (data == null) return const PlayerSystemStatus();
      final battery = data['batteryPercent'];
      final type = data['networkType'];
      final radio = data['radio'];
      return PlayerSystemStatus(
        batteryPercent: battery is int && battery >= 0 && battery <= 100
            ? battery
            : null,
        networkLabel: _labelFor(
          type is String ? type : null,
          radio is String ? radio : null,
        ),
      );
    } catch (_) {
      return const PlayerSystemStatus();
    }
  }

  static String? _labelFor(String? type, String? radio) {
    switch (type) {
      case 'wifi':
        return 'WiFi';
      case 'wired':
        return '有线';
      case 'cellular':
        final value = radio?.trim() ?? '';
        return value.isEmpty ? '蜂窝' : value;
      default:
        return null;
    }
  }
}

final playerSystemStatusReaderProvider = Provider<PlayerSystemStatusReader>(
  (ref) => const PlayerSystemStatusReader(),
);
