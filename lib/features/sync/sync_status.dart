import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_log.dart';
import 'sync_meta.dart';
import 'sync_service.dart';
import 'webdav_config.dart';

enum SyncPhase { idle, syncing, success, error, notConfigured }

@immutable
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.message = '',
    this.lastSyncAt,
  });

  final SyncPhase phase;
  final String message;
  final DateTime? lastSyncAt;

  bool get isSyncing => phase == SyncPhase.syncing;
}

final syncStatusProvider = NotifierProvider<SyncStatusController, SyncStatus>(
  SyncStatusController.new,
);

class SyncStatusController extends Notifier<SyncStatus> {
  /// 同步进行中又被请求一次时记下触发方式，本轮结束后补跑一轮。
  ///
  /// 我的页连续删几条历史 / 收藏会各请求一次同步；不补跑的话，后几条删除
  /// 可能落在本轮导出之后，要等下次前后台才上传。
  SyncTrigger? _queuedTrigger;

  @override
  SyncStatus build() => const SyncStatus();

  /// 同步一次。返回 null 表示没配置、已有同步在跑（已排队）或失败。
  ///
  /// 自动/手动都只更新状态，不向上抛错；是否提示由调用方决定。
  Future<SyncResult?> syncNow({
    SyncTrigger trigger = SyncTrigger.manual,
  }) async {
    if (state.isSyncing) {
      _queuedTrigger = trigger;
      return null;
    }
    state = const SyncStatus(phase: SyncPhase.syncing, message: '正在同步…');
    try {
      final config = await ref.read(webDavConfigProvider.future);
      if (config == null) {
        // 没配置就没必要补跑；把排队请求清掉，避免多读一次安全存储。
        _queuedTrigger = null;
        state = const SyncStatus(
          phase: SyncPhase.notConfigured,
          message: '未配置 WebDAV',
        );
        return null;
      }
      final result = await ref
          .read(webDavSyncServiceProvider)
          .sync(config, trigger: trigger);
      state = SyncStatus(
        phase: SyncPhase.success,
        message: result.uploaded
            ? '已上传本机改动'
            : result.pulled
            ? '已拉取云端更新'
            : '已是最新',
        lastSyncAt: result.syncedAt,
      );
      ref.invalidate(syncMetaProvider);
      ref.invalidate(syncLogRunsProvider);
      return result;
    } catch (error) {
      state = SyncStatus(
        phase: SyncPhase.error,
        message: error is Exception ? '$error' : '同步失败，请重试',
        lastSyncAt: state.lastSyncAt,
      );
      return null;
    } finally {
      final queued = _queuedTrigger;
      _queuedTrigger = null;
      if (queued != null && ref.mounted) {
        unawaited(syncNow(trigger: queued));
      }
    }
  }
}
