import 'dart:convert';

/// 云端设置文件 `novel-playlet/<profile>/settings.json` 的外层结构与解析。
///
/// 与 `sync.json` 完全独立：书架同步按类型模型重建 `data`，旧客户端会静默
/// 丢掉不认识的字段；设置因此单独一个文件，旧版本根本不会碰它。
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.deviceId,
    required this.updatedAt,
    required this.settings,
  });

  static const int currentVersion = 1;

  final String deviceId;
  final int updatedAt;
  final Map<String, Object?> settings;

  Map<String, Object?> toJson() => {
    'v': currentVersion,
    'deviceId': deviceId,
    'updatedAt': updatedAt,
    'settings': settings,
  };

  String encode() => jsonEncode(toJson());

  static SettingsSnapshotParse parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SettingsSnapshotInvalid();
      final map = Map<String, dynamic>.from(decoded);
      final version = map['v'];
      if (version is! int) return const SettingsSnapshotInvalid();
      if (version != currentVersion) {
        return SettingsSnapshotUnsupported(version);
      }
      final deviceId = map['deviceId'];
      final updatedAt = map['updatedAt'];
      final settings = map['settings'];
      if (deviceId is! String || deviceId.isEmpty) {
        return const SettingsSnapshotInvalid();
      }
      if (updatedAt is! int || updatedAt <= 0) {
        return const SettingsSnapshotInvalid();
      }
      if (settings is! Map) return const SettingsSnapshotInvalid();
      return SettingsSnapshotOk(
        SettingsSnapshot(
          deviceId: deviceId,
          updatedAt: updatedAt,
          settings: Map<String, Object?>.from(settings),
        ),
      );
    } catch (_) {
      return const SettingsSnapshotInvalid();
    }
  }
}

sealed class SettingsSnapshotParse {
  const SettingsSnapshotParse();
}

final class SettingsSnapshotOk extends SettingsSnapshotParse {
  const SettingsSnapshotOk(this.snapshot);

  final SettingsSnapshot snapshot;
}

/// 云端文件来自更新版本的 App：必须停止同步，绝不能把 v1 推回去覆盖它。
final class SettingsSnapshotUnsupported extends SettingsSnapshotParse {
  const SettingsSnapshotUnsupported(this.version);

  final int version;
}

final class SettingsSnapshotInvalid extends SettingsSnapshotParse {
  const SettingsSnapshotInvalid();
}

/// 设置内容的稳定指纹。
///
/// 先递归按键名排序再编码，保证同一份设置在任意设备/任意 Map 插入顺序下
/// 得到同一个值；只看 `updatedAt` 不够：两台设备同一毫秒各改一项时，时间
/// 相同但内容不同。
int hashSettings(Map<String, Object?> settings) =>
    _fnv1a(canonicalJson(settings));

/// 键名递归排序后的 JSON 字符串。
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}

int _fnv1a(String text) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}
