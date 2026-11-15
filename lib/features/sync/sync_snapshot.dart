import 'dart:convert';

/// 云同步文件的外层结构。
///
/// 数据本身仍按现有 SharedPreferences 的字段组织，外层只加版本、渠道、
/// 设备号和 revision，方便旧版本识别/迁移。
class SyncSnapshot {
  const SyncSnapshot({
    required this.schemaVersion,
    required this.profile,
    required this.deviceId,
    required this.revision,
    required this.updatedAt,
    required this.data,
  });

  static const currentSchema = 1;

  final int schemaVersion;
  final String profile;
  final String deviceId;
  final int revision;
  final int updatedAt;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'profile': profile,
    'deviceId': deviceId,
    'revision': revision,
    'updatedAt': updatedAt,
    'data': data,
  };

  String encode() => jsonEncode(toJson());

  static SyncSnapshot? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final schema = map['schemaVersion'];
      final profile = map['profile']?.toString() ?? '';
      final deviceId = map['deviceId']?.toString() ?? '';
      final revision = map['revision'];
      final updatedAt = map['updatedAt'];
      final data = map['data'];
      if (schema is! int || schema > currentSchema) return null;
      if (profile.isEmpty || deviceId.isEmpty) return null;
      if (revision is! int || updatedAt is! int) return null;
      if (data is! Map) return null;
      return SyncSnapshot(
        schemaVersion: schema,
        profile: profile,
        deviceId: deviceId,
        revision: revision,
        updatedAt: updatedAt,
        data: Map<String, dynamic>.from(data),
      );
    } catch (_) {
      return null;
    }
  }
}
