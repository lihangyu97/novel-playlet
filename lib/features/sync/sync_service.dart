import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import 'sync_log.dart';
import 'sync_meta.dart';
import 'sync_snapshot.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

class SyncResult {
  const SyncResult({
    required this.uploaded,
    required this.pulled,
    required this.syncedAt,
    this.skipped = false,
    this.revision = 0,
  });

  final bool uploaded;
  final bool pulled;
  final DateTime syncedAt;

  /// ETag 与本地指纹都没变，整轮跳过（没有网络读写）。
  final bool skipped;

  /// 本次同步后的 revision（跳过时是本地记录的值）。
  final int revision;
}

/// 一次同步：下载远端 → 合并进本地 → 再导出合并结果上传。
///
/// 合并规则在 [ReadingStore.applySyncData]；这里只负责文件格式、revision、
/// 条件请求和网络动作。远端 JSON 损坏时直接报错，绝不用空数据覆盖它。
class WebDavSyncService {
  WebDavSyncService({
    required this.store,
    required this.client,
    required this.metaStore,
    SyncLogStore? logStore,
    String? profile,
  }) : logStore = logStore ?? SyncLogStore(),
       profile = profile ?? syncProfile;

  final ReadingStore store;
  final WebDavClient client;
  final SyncMetaStore metaStore;
  final SyncLogStore logStore;
  final String profile;

  String get _dir => 'novel-playlet/$profile';
  Uri _fileUri(WebDavConfig config) => config.resolve('$_dir/sync.json');

  /// 同步一次。[trigger] 只用于同步日志，区分手动 / 生命周期 / 保存配置。
  Future<SyncResult> sync(
    WebDavConfig config, {
    SyncTrigger trigger = SyncTrigger.manual,
  }) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final phase = _SyncPhase();
    SyncMeta? metaBefore;
    try {
      metaBefore = await metaStore.read();
      phase.value = 'config';
      final invalid = config.validate();
      if (invalid != null) throw WebDavException(invalid);

      final run = await _runSync(config, metaBefore, phase);
      await _appendLog(
        startedAt: startedAt,
        trigger: trigger,
        phase: phase.value,
        metaBefore: metaBefore,
        run: run,
      );
      return run.result;
    } catch (error) {
      await _appendLog(
        startedAt: startedAt,
        trigger: trigger,
        phase: phase.value,
        metaBefore: metaBefore,
        error: error is Exception ? '$error' : '同步失败',
        failed: true,
      );
      rethrow;
    }
  }

  Future<_RunResult> _runSync(
    WebDavConfig config,
    SyncMeta meta,
    _SyncPhase phase,
  ) async {
    final uri = _fileUri(config);
    final localBefore = await store.exportSyncData();
    final localJson = jsonEncode(localBefore);

    phase.value = 'dir';
    await client.ensureDirectory(config, _dir);

    // 条件请求前置检查：云端 ETag 与本地指纹都没变时，连 GET 都不发。
    // ETag 取不到（服务器不支持 PROPFIND）就回退到原来的无条件读写。
    phase.value = 'get';
    final remoteMeta = await client.stat(config, uri);
    if (remoteMeta?.etag != null &&
        remoteMeta!.etag == meta.remoteEtag &&
        _fingerprint(localJson) == meta.localHash) {
      final syncedAt = DateTime.now();
      await metaStore.write(meta.copyWith(lastSyncAt: syncedAt));
      return _RunResult(
        result: SyncResult(
          uploaded: false,
          pulled: false,
          syncedAt: syncedAt,
          skipped: true,
          revision: meta.lastRevision,
        ),
        remoteUpdatedAt: 0,
      );
    }

    // 最多重试一次：PUT 带 If-Match，被另一台设备抢先写入时重读重合并。
    for (var attempt = 0; ; attempt++) {
      final fileMeta = attempt == 0
          ? remoteMeta
          : await client.stat(config, uri);
      final raw = await client.readText(config, uri);
      SyncSnapshot? remote;
      phase.value = 'parse';
      if (raw != null && raw.trim().isNotEmpty) {
        remote = SyncSnapshot.tryParse(raw);
        if (remote == null) {
          throw WebDavException('云端同步文件格式不正确，已停止覆盖');
        }
        if (remote.profile != profile) {
          throw WebDavException('云端同步文件属于 ${remote.profile} 渠道，已停止覆盖');
        }
      }

      phase.value = 'merge';
      final localData = await store.exportSyncData();
      if (remote != null) {
        await store.applySyncData(remote.data);
      }
      final mergedData = await store.exportSyncData();
      final mergedJson = jsonEncode(mergedData);
      final remoteJson = remote == null ? null : jsonEncode(remote.data);
      final revision = math.max(remote?.revision ?? 0, meta.lastRevision) + 1;
      final snapshot = SyncSnapshot(
        schemaVersion: SyncSnapshot.currentSchema,
        profile: profile,
        deviceId: meta.deviceId,
        revision: revision,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        data: mergedData,
      );
      final shouldUpload = remote == null || remoteJson != mergedJson;

      // 两个方向的明细在内存里就能算：拉取 = 本地合并前 → 合并后，
      // 上传 = 云端那份 → 合并结果。
      final pulled = diffLibraryData(localData, mergedData);
      final pushed = diffLibraryData(
        remote?.data ?? const {'items': <dynamic>[]},
        mergedData,
      );

      if (!shouldUpload) {
        phase.value = 'meta';
        final syncedAt = DateTime.now();
        await metaStore.write(
          meta.copyWith(
            lastRevision: math.max(remote.revision, meta.lastRevision),
            lastSyncAt: syncedAt,
            remoteEtag: fileMeta?.etag,
            localHash: _fingerprint(mergedJson),
          ),
        );
        return _RunResult(
          result: SyncResult(
            uploaded: false,
            pulled: remoteJson != jsonEncode(localData),
            syncedAt: syncedAt,
            revision: math.max(remote.revision, meta.lastRevision),
          ),
          pulled: pulled,
          pushed: pushed,
          remoteDeviceId: remote.deviceId,
          remoteUpdatedAt: remote.updatedAt,
        );
      }

      phase.value = 'put';
      try {
        await client.writeText(
          config,
          uri,
          snapshot.encode(),
          ifMatch: fileMeta?.etag,
        );
      } on WebDavPreconditionFailed {
        if (attempt >= 1) rethrow;
        continue;
      }

      phase.value = 'meta';
      final syncedAt = DateTime.now();
      // 写完再取一次 ETag：不是所有服务端都会在 PUT 响应里回 ETag。
      final after = await client.stat(config, uri);
      await metaStore.write(
        meta.copyWith(
          lastRevision: revision,
          lastSyncAt: syncedAt,
          remoteEtag: after?.etag,
          localHash: _fingerprint(mergedJson),
        ),
      );
      return _RunResult(
        result: SyncResult(
          uploaded: true,
          pulled: remoteJson != jsonEncode(localData),
          syncedAt: syncedAt,
          revision: revision,
        ),
        pulled: pulled,
        pushed: pushed,
        remoteDeviceId: remote?.deviceId ?? '',
        remoteUpdatedAt: remote?.updatedAt ?? 0,
      );
    }
  }

  /// 写日志是 best-effort：失败绝不能让同步失败。
  Future<void> _appendLog({
    required int startedAt,
    required SyncTrigger trigger,
    required String phase,
    SyncMeta? metaBefore,
    _RunResult? run,
    String? error,
    bool failed = false,
  }) async {
    final result = run?.result;
    try {
      await logStore.append(
        SyncLogRun(
          at: startedAt,
          durationMs: DateTime.now().millisecondsSinceEpoch - startedAt,
          outcome: failed
              ? SyncOutcome.failed
              : result?.skipped == true
              ? SyncOutcome.skipped
              : SyncOutcome.success,
          trigger: trigger,
          phase: failed ? phase : null,
          revBefore: metaBefore?.lastRevision ?? 0,
          revAfter: result?.revision ?? metaBefore?.lastRevision ?? 0,
          uploaded: result?.uploaded ?? false,
          remoteDeviceId: run?.remoteDeviceId ?? '',
          remoteUpdatedAt: run?.remoteUpdatedAt ?? 0,
          pulledTotal: run?.pulled.length ?? 0,
          pushedTotal: run?.pushed.length ?? 0,
          pulled: _take(run?.pulled ?? const []),
          pushed: _take(run?.pushed ?? const []),
          error: failed ? error : null,
        ),
      );
    } catch (_) {
      // 日志是诊断数据，磁盘满/权限问题都不该影响同步结果。
    }
  }

  static List<SyncLogChange> _take(List<SyncLogChange> changes) =>
      changes.take(SyncLogStore.maxChangesPerDirection).toList();
}

/// 失败阶段要一路带回日志，用一个小盒子避免给每个步骤加返回值。
class _SyncPhase {
  String value = 'config';
}

class _RunResult {
  const _RunResult({
    required this.result,
    this.pulled = const [],
    this.pushed = const [],
    this.remoteDeviceId = '',
    this.remoteUpdatedAt = 0,
  });

  final SyncResult result;
  final List<SyncLogChange> pulled;
  final List<SyncLogChange> pushed;
  final String remoteDeviceId;
  final int remoteUpdatedAt;
}

/// 本地载荷指纹（FNV-1a 64）。只用来判断"和上次同步时是否一模一样"。
int _fingerprint(String text) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}

final webDavSyncServiceProvider = Provider<WebDavSyncService>(
  (ref) => WebDavSyncService(
    store: ref.watch(readingStoreProvider),
    client: ref.watch(webDavClientProvider),
    metaStore: SyncMetaStore(),
    // 测试可以 override 成内存实现：widget 测试的 FakeAsync 里真实文件 IO
    // 不会完成，会把「保存配置后立即同步」卡在 正在同步…
    logStore: ref.watch(syncLogStoreProvider),
  ),
);
