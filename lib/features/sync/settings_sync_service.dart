import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'settings_sections.dart';
import 'settings_sync_meta.dart';
import 'settings_sync_snapshot.dart';
import 'sync_log.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

/// 一次设置同步实际做了什么。
enum SettingsSyncAction {
  /// 本地与云端一致，什么都没做。
  none,

  /// 把本地设置推到了云端。
  uploaded,

  /// 把云端设置应用到了本机。
  pulled,

  /// 云端更新了，但当前在阅读页/播放页/设置页，等离开后再应用。
  deferred,
}

@immutable
class SettingsSyncResult {
  const SettingsSyncResult({required this.action, this.updatedAt = 0});

  final SettingsSyncAction action;

  /// 本次推上去或应用的云端 `updatedAt`；`none` 时为 0。
  final int updatedAt;

  bool get changed =>
      action == SettingsSyncAction.uploaded ||
      action == SettingsSyncAction.pulled;
}

/// `settings.json` 的同步实现：拉取、LWW 判胜、推送、412 重读重判。
///
/// 它只认 [SettingsSection] 与 [WebDavClient]，不认 Riverpod：应用远端、
/// 判断沉浸页、更新时间戳都由 coordinator 以回调注入，方便单测。
class SettingsSyncService {
  SettingsSyncService({
    required this.client,
    required this.metaStore,
    required this.sections,
    required this.logStore,
    required this.profile,
    required this.isImmersive,
    required this.applyRemote,
    required this.onSyncedTimestamp,
  });

  final WebDavClient client;
  final SettingsSyncMetaStore metaStore;
  final List<SettingsSection> sections;
  final SyncLogStore logStore;
  final String profile;

  /// 阅读页/播放页/设置页压栈时为 true：只更新远端 etag，不 apply。
  final bool Function() isImmersive;

  /// 应用云端设置到各 provider；coordinator 在这里维护 `_applyingRemote`。
  final Future<void> Function(Map<String, Object?> settings, int updatedAt)
  applyRemote;

  /// 同步成功后把本地时间戳推进到云端 `updatedAt`，避免重启后误判脏。
  final Future<void> Function(int updatedAt) onSyncedTimestamp;

  String get _dir => 'novel-playlet/$profile';

  Uri _settingsUri(WebDavConfig config) =>
      config.resolve('$_dir/settings.json');

  Future<SettingsSyncResult> sync(
    WebDavConfig config, {
    required int localUpdatedAt,
    SyncTrigger trigger = SyncTrigger.lifecycle,
    int attempt = 0,
  }) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    var phase = 'config';
    try {
      final invalid = config.validate();
      if (invalid != null) throw WebDavException(invalid);

      phase = 'meta';
      final meta = await metaStore.read();
      final local = _capture();
      final localHash = hashSettings(local);
      final localDirty = localHash != meta.localHash;
      final uri = _settingsUri(config);

      phase = 'dir';
      await client.ensureDirectory(config, _dir);

      phase = 'get';
      final read = await client.readFile(config, uri);
      final raw = read.text;

      if (raw == null || raw.trim().isEmpty) {
        if (!localDirty) {
          return const SettingsSyncResult(action: SettingsSyncAction.none);
        }
        phase = 'put';
        return await _push(
          config: config,
          uri: uri,
          meta: meta,
          local: local,
          localHash: localHash,
          localUpdatedAt: localUpdatedAt,
          remoteEtag: read.etag,
          remoteUpdatedAt: 0,
          trigger: trigger,
          startedAt: startedAt,
          attempt: attempt,
        );
      }

      phase = 'parse';
      final parsed = SettingsSnapshot.parse(raw);
      if (parsed is SettingsSnapshotUnsupported) {
        throw WebDavException(
          '云端设置版本 v${parsed.version} 高于当前 App，已停止同步；请升级 App',
        );
      }
      if (parsed is! SettingsSnapshotOk) {
        throw WebDavException('云端设置文件格式不正确，已停止覆盖');
      }
      final remote = parsed.snapshot;
      for (final section in sections) {
        if (!remote.settings.containsKey(section.id)) {
          throw WebDavException('云端设置文件缺少 ${section.id}，已停止覆盖');
        }
      }
      final remoteHash = hashSettings(remote.settings);
      final remoteNewer =
          remote.updatedAt > meta.lastRemoteUpdatedAt ||
          (remote.updatedAt == meta.lastRemoteUpdatedAt &&
              remoteHash != meta.remoteHash);

      // 本地脏且比远端新：本地赢。时间相同也按远端赢，避免两台设备
      // 在同一毫秒互相覆盖。
      if (localDirty && localUpdatedAt > remote.updatedAt) {
        phase = 'put';
        return await _push(
          config: config,
          uri: uri,
          meta: meta,
          local: local,
          localHash: localHash,
          localUpdatedAt: localUpdatedAt,
          remoteEtag: read.etag,
          remoteUpdatedAt: remote.updatedAt,
          trigger: trigger,
          startedAt: startedAt,
          attempt: attempt,
        );
      }

      if (localDirty || remoteNewer) {
        // 内容一样（例如本地改回原值），只推进元数据，不触发 UI 重建。
        if (remoteHash == localHash) {
          phase = 'apply';
          await metaStore.write(
            meta.copyWith(
              remoteEtag: read.etag,
              remoteHash: remoteHash,
              localHash: remoteHash,
              lastRemoteUpdatedAt: remote.updatedAt,
              lastSyncAt: DateTime.now(),
            ),
          );
          await onSyncedTimestamp(remote.updatedAt);
          return const SettingsSyncResult(action: SettingsSyncAction.none);
        }
        phase = 'apply';
        return await _apply(
          meta: meta,
          remote: remote,
          remoteHash: remoteHash,
          etag: read.etag,
          trigger: trigger,
          startedAt: startedAt,
        );
      }

      return const SettingsSyncResult(action: SettingsSyncAction.none);
    } catch (error) {
      await _appendLog(
        startedAt: startedAt,
        trigger: trigger,
        phase: phase,
        failed: true,
        error: error is Exception ? '$error' : '设置同步失败',
      );
      rethrow;
    }
  }

  Future<SettingsSyncResult> _apply({
    required SettingsSyncMeta meta,
    required SettingsSnapshot remote,
    required int remoteHash,
    required String? etag,
    required SyncTrigger trigger,
    required int startedAt,
  }) async {
    if (isImmersive()) {
      // 只推进 etag，不推进 lastRemoteUpdatedAt：下次 resumed 还会判定
      // “远端比已应用的新”并重试。
      // 不写 remoteHash：同一毫秒内容变化时，下次靠 hash 仍能判定
      // “远端没应用过”，不会被误判成已同步。
      await metaStore.write(
        meta.copyWith(remoteEtag: etag, lastSyncAt: DateTime.now()),
      );
      return SettingsSyncResult(
        action: SettingsSyncAction.deferred,
        updatedAt: remote.updatedAt,
      );
    }

    await applyRemote(remote.settings, remote.updatedAt);
    await metaStore.write(
      meta.copyWith(
        remoteEtag: etag,
        remoteHash: remoteHash,
        localHash: remoteHash,
        lastRemoteUpdatedAt: remote.updatedAt,
        lastSyncAt: DateTime.now(),
      ),
    );
    await onSyncedTimestamp(remote.updatedAt);
    await _appendLog(
      startedAt: startedAt,
      trigger: trigger,
      phase: 'apply',
      failed: false,
      pulled: true,
      remoteUpdatedAt: remote.updatedAt,
      via: 'get',
      etag: etag,
    );
    return SettingsSyncResult(
      action: SettingsSyncAction.pulled,
      updatedAt: remote.updatedAt,
    );
  }

  Future<SettingsSyncResult> _push({
    required WebDavConfig config,
    required Uri uri,
    required SettingsSyncMeta meta,
    required Map<String, Object?> local,
    required int localHash,
    required int localUpdatedAt,
    required String? remoteEtag,
    required int remoteUpdatedAt,
    required SyncTrigger trigger,
    required int startedAt,
    required int attempt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final updatedAt = math.max(
      now,
      math.max(localUpdatedAt, remoteUpdatedAt) + 1,
    );
    final snapshot = SettingsSnapshot(
      deviceId: meta.deviceId,
      updatedAt: updatedAt,
      settings: local,
    );

    try {
      var etag = await client.writeText(
        config,
        uri,
        snapshot.encode(),
        ifMatch: remoteUpdatedAt > 0 ? remoteEtag ?? meta.remoteEtag : null,
      );
      etag ??= (await client.stat(config, uri))?.etag;
      await metaStore.write(
        meta.copyWith(
          remoteEtag: etag,
          remoteHash: localHash,
          localHash: localHash,
          lastRemoteUpdatedAt: updatedAt,
          lastSyncAt: DateTime.now(),
        ),
      );
      await onSyncedTimestamp(updatedAt);
      await _appendLog(
        startedAt: startedAt,
        trigger: trigger,
        phase: 'put',
        failed: false,
        uploaded: true,
        remoteUpdatedAt: updatedAt,
        via: 'put',
        etag: etag,
      );
      return SettingsSyncResult(
        action: SettingsSyncAction.uploaded,
        updatedAt: updatedAt,
      );
    } on WebDavPreconditionFailed {
      if (attempt >= 1) rethrow;
      // 云端在读取后被另一台设备改过：重读一次，重新按 LWW 判胜。
      return sync(
        config,
        localUpdatedAt: localUpdatedAt,
        trigger: trigger,
        attempt: attempt + 1,
      );
    }
  }

  Map<String, Object?> _capture() => {
    for (final section in sections) section.id: section.capture(),
  };

  Future<void> _appendLog({
    required int startedAt,
    required SyncTrigger trigger,
    required String? phase,
    required bool failed,
    bool uploaded = false,
    bool pulled = false,
    String? error,
    int remoteUpdatedAt = 0,
    String? via,
    String? etag,
  }) async {
    try {
      await logStore.append(
        SyncLogRun(
          at: startedAt,
          durationMs: DateTime.now().millisecondsSinceEpoch - startedAt,
          outcome: failed ? SyncOutcome.failed : SyncOutcome.success,
          trigger: trigger,
          scope: SyncScope.settings,
          phase: failed ? phase : null,
          uploaded: uploaded,
          remoteUpdatedAt: remoteUpdatedAt,
          pulledTotal: pulled ? 1 : 0,
          pushedTotal: uploaded ? 1 : 0,
          error: failed ? error : null,
          via: via,
          etag: etag,
        ),
      );
    } catch (_) {
      // 同步记录是诊断数据，写失败不能影响同步本身。
    }
  }
}
