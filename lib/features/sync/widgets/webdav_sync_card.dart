import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../sync_meta.dart';
import '../sync_status.dart';
import '../webdav_config.dart';
import 'webdav_config_sheet.dart';

const Key webDavSyncCardKey = Key('settings-webdav-sync');
const Key webDavConfigureKey = Key('settings-webdav-configure');
const Key webDavSyncNowKey = Key('settings-webdav-sync-now');

/// 设置页「WebDAV」卡片。
///
/// 配置本身在弹层里完成；这里只展示连接状态、上次同步时间和两个动作。
class WebDavSyncCard extends ConsumerWidget {
  const WebDavSyncCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            children: [
              Icon(Icons.cloud_outlined, color: scheme.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  configAsync.hasError
                      ? '读取配置失败'
                      : configured
                      ? _statusText(status, lastSync)
                      : '未配置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                key: webDavConfigureKey,
                tooltip: configured ? '修改 WebDAV' : '配置 WebDAV',
                onPressed: () => _configure(context, ref),
                icon: const Icon(Icons.edit_outlined, size: 19),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
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
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _configure(BuildContext context, WidgetRef ref) async {
    final saved = await showWebDavConfigSheet(context);
    if (!context.mounted || saved != true) return;
    ref.invalidate(webDavConfigProvider);
    // 保存成功后立即试同步一次；失败只更新状态，不打扰用户。
    await ref.read(syncStatusProvider.notifier).syncNow();
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
