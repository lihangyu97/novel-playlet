import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_meta.dart';

/// 设置同步的本地元数据。
///
/// 与 `webdav_sync_meta_v1` 完全分开：设置文件和书架文件各自独立同步，
/// etag / 指纹互不影响。
@immutable
class SettingsSyncMeta {
  const SettingsSyncMeta({
    required this.deviceId,
    this.remoteEtag,
    this.remoteHash = 0,
    this.localHash = 0,
    this.lastRemoteUpdatedAt = 0,
    this.lastSyncAt,
  });

  final String deviceId;
  final String? remoteEtag;

  /// 最近一次成功同步时云端设置内容的指纹。
  final int remoteHash;

  /// 最近一次成功同步时本地设置内容的指纹。
  final int localHash;

  /// 最近一次成功应用/上传的云端 `updatedAt`。
  ///
  /// 拉取被沉浸页挡住时**不推进**，下次 resumed 会重试。
  final int lastRemoteUpdatedAt;

  final DateTime? lastSyncAt;

  SettingsSyncMeta copyWith({
    String? remoteEtag,
    int? remoteHash,
    int? localHash,
    int? lastRemoteUpdatedAt,
    DateTime? lastSyncAt,
  }) => SettingsSyncMeta(
    deviceId: deviceId,
    remoteEtag: remoteEtag ?? this.remoteEtag,
    remoteHash: remoteHash ?? this.remoteHash,
    localHash: localHash ?? this.localHash,
    lastRemoteUpdatedAt: lastRemoteUpdatedAt ?? this.lastRemoteUpdatedAt,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
  );

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    if (remoteEtag != null) 'remoteEtag': remoteEtag,
    'remoteHash': remoteHash,
    'localHash': localHash,
    'lastRemoteUpdatedAt': lastRemoteUpdatedAt,
    if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.millisecondsSinceEpoch,
  };

  static SettingsSyncMeta fromJson(Map<String, dynamic> json) {
    final rawSyncAt = json['lastSyncAt'];
    final storedDeviceId = json['deviceId']?.toString() ?? '';
    return SettingsSyncMeta(
      deviceId: storedDeviceId.isEmpty ? newDeviceId() : storedDeviceId,
      remoteEtag: json['remoteEtag']?.toString(),
      remoteHash: json['remoteHash'] is int ? json['remoteHash'] as int : 0,
      localHash: json['localHash'] is int ? json['localHash'] as int : 0,
      lastRemoteUpdatedAt: json['lastRemoteUpdatedAt'] is int
          ? json['lastRemoteUpdatedAt'] as int
          : 0,
      lastSyncAt: rawSyncAt is int
          ? DateTime.fromMillisecondsSinceEpoch(rawSyncAt)
          : null,
    );
  }
}

class SettingsSyncMetaStore {
  static const storageKey = 'settings_sync_meta_v1';

  Future<SettingsSyncMeta> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return SettingsSyncMeta.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // 损坏的元数据按新设备处理。
      }
    }
    final fresh = SettingsSyncMeta(deviceId: newDeviceId());
    await write(fresh);
    return fresh;
  }

  Future<void> write(SettingsSyncMeta meta) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(meta.toJson()));
  }
}

/// 本地设置最后一次变更的时间。
///
/// 单独一个 key，不和远端元数据共用文件：设置变更时只需要写这一项，不会
/// 和网络层的 read-modify-write 抢同一份 meta。设置文件用这个时间做 LWW，
/// 重启后仍然知道「本地改得比云端新还是旧」。
class SettingsLocalTimestampStore {
  static const storageKey = 'settings_local_updated_at_v1';

  Future<int> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(storageKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> write(int millisecondsSinceEpoch) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(storageKey, millisecondsSinceEpoch);
    } catch (_) {
      // 时间戳写失败只影响下次启动的冲突判定，当前会话仍有内存值。
    }
  }
}
