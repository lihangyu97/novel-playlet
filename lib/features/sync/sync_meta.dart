import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_version.dart';

/// 当前构建渠道对应的远端目录。
///
/// debug 用 dev，避免本地调试包覆盖 release 数据；beta/release 严格分开。
String get syncProfile {
  if (appFlavor == 'beta') return 'beta';
  if (kReleaseMode) return 'release';
  return 'dev';
}

/// 远端根目录下的相对目录；实际文件为 `<dir>/sync.json`。
String get syncRemoteDir => 'novel-playlet/$syncProfile';

/// 本地同步元数据：设备号、上次 revision、上次同步时间。
@immutable
class SyncMeta {
  const SyncMeta({
    required this.deviceId,
    this.lastRevision = 0,
    this.lastSyncAt,
    this.remoteEtag,
    this.localHash = 0,
  });

  final String deviceId;
  final int lastRevision;
  final DateTime? lastSyncAt;

  /// 上次成功同步时云端文件的 ETag；同一份文件再同步时可以整轮跳过。
  final String? remoteEtag;

  /// 上次成功同步后本地载荷的指纹（FNV-1a 64）。
  ///
  /// 只看 ETag 不够：本机可能又翻了几页，云端没变但本地有未上传的变更。
  /// 两个都相同才是真的"没变化"。
  final int localHash;

  SyncMeta copyWith({
    int? lastRevision,
    DateTime? lastSyncAt,
    String? remoteEtag,
    int? localHash,
  }) => SyncMeta(
    deviceId: deviceId,
    lastRevision: lastRevision ?? this.lastRevision,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    remoteEtag: remoteEtag ?? this.remoteEtag,
    localHash: localHash ?? this.localHash,
  );

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'lastRevision': lastRevision,
    'lastSyncAt': lastSyncAt?.millisecondsSinceEpoch,
    if (remoteEtag != null) 'remoteEtag': remoteEtag,
    if (localHash != 0) 'localHash': localHash,
  };

  static SyncMeta fromJson(Map<String, dynamic> json) => SyncMeta(
    deviceId: json['deviceId']?.toString() ?? newDeviceId(),
    lastRevision: json['lastRevision'] is int ? json['lastRevision'] as int : 0,
    lastSyncAt: json['lastSyncAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(json['lastSyncAt'] as int)
        : null,
    remoteEtag: json['remoteEtag']?.toString(),
    localHash: json['localHash'] is int ? json['localHash'] as int : 0,
  );
}

class SyncMetaStore {
  static const storageKey = 'webdav_sync_meta_v1';

  Future<SyncMeta> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return SyncMeta.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // 损坏的元数据按新设备处理。
      }
    }
    final fresh = SyncMeta(deviceId: newDeviceId());
    await write(fresh);
    return fresh;
  }

  Future<void> write(SyncMeta meta) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(meta.toJson()));
  }
}

String newDeviceId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

final Random _random = Random.secure();

final syncMetaProvider = FutureProvider<SyncMeta>(
  (ref) => SyncMetaStore().read(),
);
