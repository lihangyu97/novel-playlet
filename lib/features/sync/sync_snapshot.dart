import 'dart:convert';

/// 云同步文件的外层结构。
///
/// `data` 的结构随 [currentSchema] 演进：
/// - 1：`novelShelf` / `novelShelfMeta` / `novelProgress` / …（旧 prefs 形状）
/// - 2：`novel` / `video` 两个记录数组（状态/快照拆表的中间版本）
/// - 3：`items` 一个记录数组，每条带 `type`（`novel` / `playlet`）。
///   小说与短剧共用一张表，见 `docs/storage-model-proposal.md`。
///
/// **只认当前版本**：读到旧版本直接判为不合法，由同步层报
/// 「云端同步文件格式不正确，已停止覆盖」——绝不按新结构去解析旧数据，
/// 也绝不用空数据覆盖远端。旧文件需要手工转换（或清空后重新同步）。
class SyncSnapshot {
  const SyncSnapshot({
    required this.schemaVersion,
    required this.profile,
    required this.deviceId,
    required this.revision,
    required this.updatedAt,
    required this.data,
  });

  static const currentSchema = 3;

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
      if (schema is! int || schema != currentSchema) return null;
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
