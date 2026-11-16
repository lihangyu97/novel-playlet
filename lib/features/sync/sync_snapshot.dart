import 'dart:convert';

/// 云同步文件的外层结构。
///
/// `data` 的结构随 [currentSchema] 演进：
/// - 1：`novelShelf` / `novelShelfMeta` / `novelProgress` / `videoShelf` /
///   `videoShelfMeta` / `videoProgress`（shared_preferences 时代的形状）；
/// - 2：`novel` / `video` 两个记录数组，一条记录同时带上游快照与用户状态
///   （见 `docs/storage-model-proposal.md`）。
///
/// 读到低版本不用报错：`ReadingStore.applySyncData` 会把 v1 载荷转成记录再
/// 合并，升级后第一次同步不会卡在"格式不正确"。
class SyncSnapshot {
  const SyncSnapshot({
    required this.schemaVersion,
    required this.profile,
    required this.deviceId,
    required this.revision,
    required this.updatedAt,
    required this.data,
  });

  static const currentSchema = 2;

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
