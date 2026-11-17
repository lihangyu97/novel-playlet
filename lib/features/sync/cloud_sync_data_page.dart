import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/states.dart';
import '../../core/relative_time.dart';
import '../../core/storage/library_records.dart';
import '../../data/models/json_utils.dart';
import '../mine/widgets/library_type_badge.dart';
import 'sync_meta.dart';
import 'sync_snapshot.dart';
import 'webdav_client.dart';
import 'webdav_config.dart';

/// 云端 `sync.json` 的只读视图。
///
/// `null`（provider 返回）表示还没配置 WebDAV；[isEmpty] 表示已配置但云端
/// 还没有同步文件。两者要分开提示，不能都当"空列表"。
class CloudSyncData {
  const CloudSyncData.absent() : snapshot = null, etag = null;

  const CloudSyncData.ready(SyncSnapshot this.snapshot, this.etag);

  final SyncSnapshot? snapshot;
  final String? etag;

  bool get isEmpty => snapshot == null;
}

/// 读取云端 `sync.json`（只读，不写、不合并）。
///
/// 复用同步用的同一套 [WebDavClient] 与 [syncRemoteDir]：渠道（release/beta/dev）
/// 不同就是不同文件，和真实同步看到的完全一致。
final cloudSyncSnapshotProvider = FutureProvider.autoDispose<CloudSyncData?>((
  ref,
) async {
  final config = await ref.watch(webDavConfigProvider.future);
  if (config == null) return null;
  final client = ref.watch(webDavClientProvider);
  final read = await client.readFile(
    config,
    config.resolve('$syncRemoteDir/sync.json'),
  );
  final raw = read.text;
  if (raw == null || raw.trim().isEmpty) return const CloudSyncData.absent();
  final snapshot = SyncSnapshot.tryParse(raw);
  if (snapshot == null) {
    throw const FormatException('云端 sync.json 格式不正确');
  }
  return CloudSyncData.ready(snapshot, read.etag);
});

/// 云端数据页：顶部是 sync.json 的元信息，下面是列表（最多 500 个）。
class CloudSyncDataPage extends ConsumerWidget {
  const CloudSyncDataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(cloudSyncSnapshotProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('云端数据'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(cloudSyncSnapshotProvider),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          message: '读取云端数据失败',
          onRetry: () => ref.invalidate(cloudSyncSnapshotProvider),
        ),
        data: (value) {
          if (value == null) {
            return const EmptyView(
              message: '还没有配置 WebDAV',
              icon: Icons.cloud_off_outlined,
            );
          }
          if (value.isEmpty) {
            return const EmptyView(
              message: '云端还没有同步数据',
              icon: Icons.cloud_queue_outlined,
            );
          }
          return _CloudSyncDataBody(
            data: value,
            onRefresh: () async {
              ref.invalidate(cloudSyncSnapshotProvider);
              await ref.read(cloudSyncSnapshotProvider.future);
            },
          );
        },
      ),
    );
  }
}

class _CloudSyncDataBody extends StatelessWidget {
  const _CloudSyncDataBody({required this.data, required this.onRefresh});

  final CloudSyncData data;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final snapshot = data.snapshot!;
    final records = _recordsOf(snapshot);
    final novels = records.where((r) => !r.type.isPlaylet).length;
    final playlets = records.length - novels;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _MetaCard(snapshot: snapshot)),
          SliverToBoxAdapter(
            child: _ListHeader(
              count: records.length,
              novels: novels,
              playlets: playlets,
            ),
          ),
          if (records.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: EmptyView(message: '云端列表为空', icon: Icons.inbox_outlined),
              ),
            )
          else
            SliverList.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _RecordTile(record: records[index]),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }
}

List<LibraryRecord> _recordsOf(SyncSnapshot snapshot) {
  final records = <LibraryRecord>[];
  for (final raw in asList(snapshot.data['items'])) {
    final record = LibraryRecord.tryFromJson(raw);
    if (record != null) records.add(record);
  }
  // 云端按主键排序（同步文件本身要稳定）；展示按「最近读/最近收藏」排，
  // 读起来更接近「我的」页。
  records.sort((a, b) {
    final byRead = b.lastReadAt.compareTo(a.lastReadAt);
    if (byRead != 0) return byRead;
    final byShelf = b.shelfAt.compareTo(a.shelfAt);
    if (byShelf != 0) return byShelf;
    return a.title.compareTo(b.title);
  });
  return records;
}

class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.snapshot});

  final SyncSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updated = DateTime.fromMillisecondsSinceEpoch(snapshot.updatedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_done_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('云端 sync.json', style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: 12),
              _MetaRow(label: '设备 ID', value: snapshot.deviceId),
              _MetaRow(
                label: '更新时间',
                value: '${relativeTime(updated)}（${_absoluteTime(updated)}）',
              ),
              _MetaRow(label: '云端版本', value: '第 ${snapshot.revision} 版'),
              _MetaRow(label: '渠道', value: snapshot.profile),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader({
    required this.count,
    required this.novels,
    required this.playlets,
  });

  final int count;
  final int novels;
  final int playlets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('同步列表', style: theme.textTheme.titleSmall),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '共 $count 条 · 小说 $novels · 短剧 $playlets',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '最多 500 个',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final LibraryRecord record;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: LibraryTypeBadge(type: record.type),
      title: Text(
        record.title.isEmpty ? record.sourceId : record.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _subtitleOf(record),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

String _subtitleOf(LibraryRecord record) {
  final parts = <String>[];
  if (record.hasProgress) {
    parts.add(
      record.type.isPlaylet
          ? '第 ${record.progressIndex + 1} 集'
          : '第 ${record.progressIndex + 1} 章',
    );
  }
  if (record.onShelf) {
    parts.add('已收藏');
  } else if (record.isTombstone) {
    parts.add('已移出收藏');
  }
  if (record.lastReadAt > 0) {
    parts.add(
      relativeTime(DateTime.fromMillisecondsSinceEpoch(record.lastReadAt)),
    );
  }
  return parts.isEmpty ? '无进度' : parts.join(' · ');
}

String _absoluteTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
