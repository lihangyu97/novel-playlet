import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import 'sync_meta.dart';
import 'sync_snapshot.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

class SyncResult {
  const SyncResult({
    required this.uploaded,
    required this.pulled,
    required this.syncedAt,
  });

  final bool uploaded;
  final bool pulled;
  final DateTime syncedAt;
}

/// 一次同步：下载远端 → 合并进本地 → 再导出合并结果上传。
///
/// 合并规则在 [ReadingStore.applySyncData]；这里只负责文件格式、revision
/// 和网络动作。远端 JSON 损坏时直接报错，绝不用空数据覆盖它。
class WebDavSyncService {
  WebDavSyncService({
    required this.store,
    required this.client,
    required this.metaStore,
    String? profile,
  }) : profile = profile ?? syncProfile;

  final ReadingStore store;
  final WebDavClient client;
  final SyncMetaStore metaStore;
  final String profile;

  String get _dir => 'novel-playlet/$profile';
  Uri _fileUri(WebDavConfig config) => config.resolve('$_dir/sync.json');

  Future<SyncResult> sync(WebDavConfig config) async {
    final invalid = config.validate();
    if (invalid != null) throw WebDavException(invalid);

    await client.ensureDirectory(config, _dir);
    final raw = await client.readText(config, _fileUri(config));
    SyncSnapshot? remote;
    if (raw != null && raw.trim().isNotEmpty) {
      remote = SyncSnapshot.tryParse(raw);
      if (remote == null) {
        throw WebDavException('云端同步文件格式不正确，已停止覆盖');
      }
      if (remote.profile != profile) {
        throw WebDavException('云端同步文件属于 ${remote.profile} 渠道，已停止覆盖');
      }
    }

    final meta = await metaStore.read();
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
    if (shouldUpload) {
      await client.writeText(config, _fileUri(config), snapshot.encode());
    }
    final syncedAt = DateTime.now();
    await metaStore.write(
      meta.copyWith(
        lastRevision: shouldUpload ? revision : remote.revision,
        lastSyncAt: syncedAt,
      ),
    );
    return SyncResult(
      uploaded: shouldUpload,
      pulled: remote != null && remoteJson != jsonEncode(localData),
      syncedAt: syncedAt,
    );
  }
}

final webDavSyncServiceProvider = Provider<WebDavSyncService>(
  (ref) => WebDavSyncService(
    store: ref.watch(readingStoreProvider),
    client: ref.watch(webDavClientProvider),
    metaStore: SyncMetaStore(),
  ),
);
