import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  @override
  SyncStatus build() => const SyncStatus();

  /// 同步一次。返回 null 表示没配置或已有同步在跑。
  ///
  /// 自动/手动都只更新状态，不向上抛错；是否提示由调用方决定。
  Future<SyncResult?> syncNow() async {
    if (state.isSyncing) return null;
    state = const SyncStatus(phase: SyncPhase.syncing, message: '正在同步…');
    try {
      final config = await ref.read(webDavConfigProvider.future);
      if (config == null) {
        state = const SyncStatus(
          phase: SyncPhase.notConfigured,
          message: '未配置 WebDAV',
        );
        return null;
      }
      final result = await ref.read(webDavSyncServiceProvider).sync(config);
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
      return result;
    } catch (error) {
      state = SyncStatus(
        phase: SyncPhase.error,
        message: error is Exception ? '$error' : '同步失败，请重试',
        lastSyncAt: state.lastSyncAt,
      );
      return null;
    }
  }
}
