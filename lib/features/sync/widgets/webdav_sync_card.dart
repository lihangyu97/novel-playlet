import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_theme.dart';
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
/// 行样式跟设置页其它卡片一致（`titleSmall` 标题 + 右侧控件，40pt 行高、
/// 卡片内 16 横向内边距），不再用 `ListTile` 的图标/副标题形态。三个入口
/// 都是导航/动作，副标题只在配置行用状态文字（右侧）表达。
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
            _EntryRow(
              key: webDavConfigureKey,
              title: 'WebDAV 配置',
              onTap: () => _configure(context, ref),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 128),
                    child: Text(
                      configAsync.hasError
                          ? '读取配置失败'
                          : configured
                          ? _statusText(status, lastSync)
                          : '未配置',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    key: webDavSyncNowKey,
                    tooltip: '立即同步',
                    onPressed: !configured || status.isSyncing
                        ? null
                        : () => _syncNow(context, ref),
                    icon: status.isSyncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 20),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _EntryRow(
              key: webDavLogKey,
              title: '同步记录',
              onTap: () => context.pushAppRoute(const SyncLogRoute()),
              trailing: Icon(
                Icons.chevron_right,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _EntryRow(
              key: webDavCloudDataKey,
              title: '云端数据',
              onTap: () => context.pushAppRoute(const CloudSyncDataRoute()),
              trailing: Icon(
                Icons.chevron_right,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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

/// 设置页风格的一行：标题左、右侧控件，整行可点。
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.title,
    this.trailing,
    required this.onTap,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: context.appWeight(FontWeight.w600),
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
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
