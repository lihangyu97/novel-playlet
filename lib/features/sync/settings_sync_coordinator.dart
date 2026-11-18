import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/immersive_page.dart';
import '../../app/theme/app_font_weight.dart';
import '../../app/theme/theme_settings.dart';
import '../reader/reader_settings.dart';
import '../recommend/recommend_layout.dart';
import 'settings_sections.dart';
import 'settings_sync_meta.dart';
import 'settings_sync_service.dart';
import 'settings_sync_snapshot.dart';
import 'sync_log.dart';
import 'sync_meta.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

enum SettingsSyncPhase {
  idle,
  syncing,
  success,
  error,
  notConfigured,

  /// 本地有改动，等去抖/退后台/离开设置页时推送。
  pending,

  /// 云端有更新，但当前在沉浸页，等离开后再应用。
  deferred,
}

@immutable
class SettingsSyncStatus {
  const SettingsSyncStatus({
    this.phase = SettingsSyncPhase.idle,
    this.message = '',
    this.lastSyncAt,
  });

  final SettingsSyncPhase phase;
  final String message;
  final DateTime? lastSyncAt;

  bool get isSyncing => phase == SettingsSyncPhase.syncing;

  bool get isPending => phase == SettingsSyncPhase.pending;
}

final settingsSyncStatusProvider =
    NotifierProvider<SettingsSyncCoordinator, SettingsSyncStatus>(
      SettingsSyncCoordinator.new,
    );

/// 设置同步的脏标记、去抖、单飞与状态。
///
/// 监听 6 个设置 controller 的变更（主题色/自定义色/深浅色/全局字重/推荐
/// 布局/阅读排版），1.6s 去抖后推一次；远端 apply 期间用 `_applyingRemote`
/// 屏蔽自己的监听，避免 pull → 脏 → push 的乒乓。
class SettingsSyncCoordinator extends Notifier<SettingsSyncStatus> {
  final SettingsSyncMetaStore _metaStore = SettingsSyncMetaStore();
  final SettingsLocalTimestampStore _localStore = SettingsLocalTimestampStore();

  Timer? _debounce;
  Future<void>? _ready;
  bool _started = false;
  bool _syncing = false;
  bool _syncAgain = false;
  bool _dirty = false;
  bool _applyingRemote = false;
  int _localUpdatedAt = 0;

  @override
  SettingsSyncStatus build() {
    // 6 个设置来源；任一变化都可能是本地编辑，也可能是 applyRemote。
    ref.listen(themeSeedProvider, (_, _) => _onLocalChanged());
    ref.listen(customThemeSeedProvider, (_, _) => _onLocalChanged());
    ref.listen(themeModeProvider, (_, _) => _onLocalChanged());
    ref.listen(appFontWeightProvider, (_, _) => _onLocalChanged());
    ref.listen(recommendLayoutProvider, (_, _) => _onLocalChanged());
    ref.listen(readerSettingsProvider, (_, _) => _onLocalChanged());
    // 离开阅读/播放/设置页后如果还有 deferred 的云端设置，立刻补一次 apply。
    ref.listen(immersivePageProvider, (previous, next) {
      if ((previous ?? 0) > 0 &&
          next == 0 &&
          state.phase == SettingsSyncPhase.deferred) {
        unawaited(syncNow(trigger: SyncTrigger.lifecycle));
      }
    });

    ref.onDispose(() => _debounce?.cancel());
    _ready = _initialize();
    return const SettingsSyncStatus();
  }

  Future<void> _initialize() async {
    try {
      await Future.wait([
        ref.read(themeSeedProvider.notifier).restoreFuture,
        ref.read(customThemeSeedProvider.notifier).restoreFuture,
        ref.read(themeModeProvider.notifier).restoreFuture,
        ref.read(appFontWeightProvider.notifier).restoreFuture,
        ref.read(recommendLayoutProvider.notifier).restoreFuture,
        ref.read(readerSettingsProvider.notifier).restoreFuture,
      ]);
      final meta = await _metaStore.read();
      _localUpdatedAt = await _localStore.read();
      _dirty = hashSettings(_capture()) != meta.localHash;
      _started = true;
      if (!ref.mounted) return;
      state = SettingsSyncStatus(
        phase: _dirty ? SettingsSyncPhase.pending : SettingsSyncPhase.idle,
        message: _dirty ? '待上传' : '',
      );
    } catch (error) {
      _started = true;
      if (!ref.mounted) return;
      state = SettingsSyncStatus(
        phase: SettingsSyncPhase.error,
        message: error is Exception ? '$error' : '读取设置同步状态失败',
      );
    }
  }

  /// 手动「立即同步」或生命周期触发。
  ///
  /// 已有同步在跑时记一个 `_syncAgain`，结束后再补一轮，避免设置变更被
  /// 一次单飞锁吞掉。
  Future<void> syncNow({SyncTrigger trigger = SyncTrigger.manual}) async {
    await _ready;
    if (!ref.mounted) return;
    _debounce?.cancel();
    if (_syncing) {
      _syncAgain = true;
      return;
    }

    WebDavConfig? config;
    try {
      config = await ref.read(webDavConfigProvider.future);
    } catch (error) {
      if (!ref.mounted) return;
      state = SettingsSyncStatus(
        phase: SettingsSyncPhase.error,
        message: error is Exception ? '$error' : '读取 WebDAV 配置失败',
        lastSyncAt: state.lastSyncAt,
      );
      return;
    }
    if (!ref.mounted) return;
    if (config == null) {
      state = SettingsSyncStatus(
        phase: SettingsSyncPhase.notConfigured,
        message: '未配置 WebDAV',
        lastSyncAt: state.lastSyncAt,
      );
      return;
    }

    _syncing = true;
    state = SettingsSyncStatus(
      phase: SettingsSyncPhase.syncing,
      message: '正在同步设置…',
      lastSyncAt: state.lastSyncAt,
    );

    try {
      final service = SettingsSyncService(
        client: ref.read(webDavClientProvider),
        metaStore: _metaStore,
        sections: ref.read(settingsSectionsProvider),
        logStore: ref.read(syncLogStoreProvider),
        profile: syncProfile,
        isImmersive: () => ref.read(immersivePageProvider) > 0,
        applyRemote: _applyRemoteSettings,
        onSyncedTimestamp: _onSyncedTimestamp,
      );
      final result = await service.sync(
        config,
        localUpdatedAt: _localUpdatedAt,
        trigger: trigger,
      );
      final meta = await _metaStore.read();
      _localUpdatedAt = await _localStore.read();
      _dirty = hashSettings(_capture()) != meta.localHash;
      if (ref.mounted) {
        state = SettingsSyncStatus(
          phase: result.action == SettingsSyncAction.deferred
              ? SettingsSyncPhase.deferred
              : SettingsSyncPhase.success,
          message: _messageFor(result.action),
          lastSyncAt: DateTime.now(),
        );
      }
      ref.invalidate(syncLogRunsProvider);
      // 网络请求期间用户可能已经离开沉浸页：下一轮立刻重试。
      if (result.action == SettingsSyncAction.deferred &&
          ref.read(immersivePageProvider) == 0) {
        _syncAgain = true;
      }
      if (_dirty && ref.mounted) {
        _schedulePush();
      }
    } catch (error) {
      if (ref.mounted) {
        state = SettingsSyncStatus(
          phase: SettingsSyncPhase.error,
          message: error is Exception ? '$error' : '设置同步失败',
          lastSyncAt: state.lastSyncAt,
        );
      }
      ref.invalidate(syncLogRunsProvider);
    } finally {
      _syncing = false;
      if (_syncAgain) {
        _syncAgain = false;
        if (ref.mounted) {
          unawaited(syncNow(trigger: SyncTrigger.settings));
        }
      }
    }
  }

  /// 离开设置页 / 退后台时把去抖中的改动立刻推上去。
  Future<void> flush() async {
    _debounce?.cancel();
    await _ready;
    if (!ref.mounted) return;
    if (_dirty) {
      // 已在下一次同步的补跑队列里就不重复排。
      if (_syncing) {
        _syncAgain = true;
        return;
      }
      await syncNow(trigger: SyncTrigger.settings);
    }
  }

  void _onLocalChanged() {
    if (!_started || _applyingRemote) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _localUpdatedAt = now;
    _dirty = true;
    unawaited(_localStore.write(now));
    if (ref.mounted) {
      state = SettingsSyncStatus(
        phase: SettingsSyncPhase.pending,
        message: '待上传',
        lastSyncAt: state.lastSyncAt,
      );
    }
    _schedulePush();
  }

  void _schedulePush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1600), () {
      if (ref.mounted) unawaited(syncNow(trigger: SyncTrigger.settings));
    });
  }

  Future<void> _applyRemoteSettings(
    Map<String, Object?> settings,
    int updatedAt,
  ) async {
    _applyingRemote = true;
    try {
      for (final section in ref.read(settingsSectionsProvider)) {
        await section.applyRemote(settings[section.id]);
      }
      _localUpdatedAt = math.max(_localUpdatedAt, updatedAt);
      await _localStore.write(_localUpdatedAt);
      _dirty = false;
    } finally {
      _applyingRemote = false;
    }
  }

  Future<void> _onSyncedTimestamp(int updatedAt) async {
    _localUpdatedAt = math.max(_localUpdatedAt, updatedAt);
    await _localStore.write(_localUpdatedAt);
  }

  Map<String, Object?> _capture() => {
    for (final section in ref.read(settingsSectionsProvider))
      section.id: section.capture(),
  };

  String _messageFor(SettingsSyncAction action) => switch (action) {
    SettingsSyncAction.uploaded => '设置已上传',
    SettingsSyncAction.pulled => '设置已拉取',
    SettingsSyncAction.deferred => '阅读中，稍后应用云端设置',
    SettingsSyncAction.none => '设置已是最新',
  };
}
