import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../sync_log.dart';
import '../sync_meta.dart';
import '../sync_status.dart';
import '../webdav_config.dart';
import 'webdav_config_sheet.dart';

const Key webDavSyncCardKey = Key('settings-webdav-sync');
const Key webDavConfigureKey = Key('settings-webdav-configure');
const Key webDavSyncNowKey = Key('settings-webdav-sync-now');
const Key webDavLogKey = Key('webdav-log-entry');
const Key webDavCloudDataKey = Key('settings-webdav-cloud-data');

/// 设置页「WebDAV」卡片：配置 / 同步记录 / 云端数据 三个一级入口。
///
/// 配置本身在弹层里完成；卡片第一行展示连接状态 + 立即同步，后两行跳到
/// 本机同步日志与云端 `sync.json` 只读页。
class WebDavSyncCard extends ConsumerWidget {
  const WebDavSyncCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(webDavConfigProvider);
    final status = ref.watch(syncStatusProvider);
    final metaAsync = ref.watch(syncMetaProvider);
    final config = configAsync.value;
    final lastSync = status.lastSyncAt ?? metaAsync.value?.lastSyncAt;
    final configured = config != null;

    return Padding(
      key: webDavSyncCardKey,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              key: webDavConfigureKey,
              leading: const Icon(Icons.cloud_outlined, size: 20),
              title: const Text('WebDAV 配置'),
              subtitle: Text(
                configAsync.hasError
                    ? '读取配置失败'
                    : configured
                    ? _statusText(status, lastSync)
                    : '未配置',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                key: webDavSyncNowKey,
                tooltip: '立即同步',
                onPressed: !configured || status.isSyncing
                    ? null
                    : () => _syncNow(context, ref),
                icon: status.isSyncing
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              onTap: () => _configure(context, ref),
              visualDensity: VisualDensity.compact,
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              key: webDavLogKey,
              leading: const Icon(Icons.history_rounded, size: 20),
              title: const Text('同步记录'),
              subtitle: const Text('最近 50 次同步的结果与双向明细'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => context.pushAppRoute(const SyncLogRoute()),
              visualDensity: VisualDensity.compact,
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              key: webDavCloudDataKey,
              leading: const Icon(Icons.cloud_download_outlined, size: 20),
              title: const Text('云端数据'),
              subtitle: const Text('查看云端 sync.json 的元信息与列表'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => context.pushAppRoute(const CloudSyncDataRoute()),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configure(BuildContext context, WidgetRef ref) async {
    final saved = await showWebDavConfigSheet(context);
    if (!context.mounted || saved != true) return;
    ref.invalidate(webDavConfigProvider);
    // 保存成功后立即试同步一次；失败只更新状态，不打扰用户。
    await ref
        .read(syncStatusProvider.notifier)
        .syncNow(trigger: SyncTrigger.config);
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final result = await ref.read(syncStatusProvider.notifier).syncNow();
    if (!context.mounted) return;
    final status = ref.read(syncStatusProvider);
    if (status.phase == SyncPhase.error) {
      showAppSnackBar(context, status.message);
    } else if (result != null) {
      showAppSnackBar(context, status.message);
    }
  }
}

String _statusText(SyncStatus status, DateTime? lastSync) {
  if (status.isSyncing) return '正在同步…';
  if (status.phase == SyncPhase.error) return '同步失败';
  final time = lastSync == null ? null : _formatTime(lastSync);
  return time == null ? '尚未同步' : '上次同步 $time';
}

String _formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
