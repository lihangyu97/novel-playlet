import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/states.dart';
import '../mine/widgets/library_type_badge.dart';
import 'sync_log.dart';

/// 同步记录：最近 50 次同步的结果与双向明细。
///
/// 入口在 WebDAV 配置弹层。日志只在本机（`<AppSupport>/sync-log.json`），
/// 不进同步载荷，也不进 `library.db`。
class SyncLogPage extends ConsumerWidget {
  const SyncLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(syncLogRunsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步记录'),
        actions: [
          runs.maybeWhen(
            data: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空记录',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _clear(context, ref),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: runs.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          message: '读取同步记录失败',
          onRetry: () => ref.invalidate(syncLogRunsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyView(
              message: '还没有同步记录',
              icon: Icons.history_rounded,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final run = items[index];
              final previous = index == 0 ? null : items[index - 1];
              final showDay =
                  previous == null || !_sameDay(previous.atTime, run.atTime);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showDay) _DayHeader(day: run.atTime),
                  _RunTile(run: run),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空同步记录？'),
        content: const Text('只删除本机的诊断记录，不影响书架和云端数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(syncLogStoreProvider).clear();
    ref.invalidate(syncLogRunsProvider);
    if (context.mounted) showAppSnackBar(context, '已清空同步记录');
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        _dayLabel(day),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RunTile extends StatefulWidget {
  const _RunTile({required this.run});

  final SyncLogRun run;

  @override
  State<_RunTile> createState() => _RunTileState();
}

class _RunTileState extends State<_RunTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final run = widget.run;
    final hasDetail =
        run.error != null || run.pulled.isNotEmpty || run.pushed.isNotEmpty;
    final color = switch (run.outcome) {
      SyncOutcome.success => scheme.primary,
      SyncOutcome.failed => scheme.error,
      SyncOutcome.skipped => scheme.onSurfaceVariant,
    };
    final icon = switch (run.outcome) {
      SyncOutcome.success => Icons.check_circle_outline_rounded,
      SyncOutcome.failed => Icons.error_outline_rounded,
      SyncOutcome.skipped => Icons.remove_circle_outline_rounded,
    };

    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: hasDetail ? () => setState(() => _expanded = !_expanded) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      _timeLabel(run.atTime),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Icon(icon, size: 17, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _summary(run),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: run.outcome == SyncOutcome.failed
                            ? scheme.error
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'r${run.revBefore} → r${run.revAfter}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 44,
                    child: Text(
                      _durationLabel(run.durationMs),
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (hasDetail)
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                ],
              ),
              if (run.error != null) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 69),
                  child: Text(
                    run.error!,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
              if (_expanded) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 69),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _metaLine(context, run),
                      if (run.pulled.isNotEmpty)
                        _ChangeSection(
                          title: '拉取到本机',
                          total: run.pulledTotal,
                          changes: run.pulled,
                        ),
                      if (run.pushed.isNotEmpty)
                        _ChangeSection(
                          title: '上传到云端',
                          total: run.pushedTotal,
                          changes: run.pushed,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaLine(BuildContext context, SyncLogRun run) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      '触发：${switch (run.trigger) {
        SyncTrigger.manual => '手动',
        SyncTrigger.lifecycle => '前后台',
        SyncTrigger.config => '保存配置',
      }}',
      if (run.remoteUpdatedAt > 0)
        '云端：${_timeLabel(DateTime.fromMillisecondsSinceEpoch(run.remoteUpdatedAt))} 生成',
      if (run.remoteDeviceId.isNotEmpty)
        '设备 ${_deviceLabel(run.remoteDeviceId)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        parts.join(' · '),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _ChangeSection extends StatelessWidget {
  const _ChangeSection({
    required this.title,
    required this.total,
    required this.changes,
  });

  final String title;
  final int total;
  final List<SyncLogChange> changes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = total - changes.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title（$total）',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _ChangeRow(change: change),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '另有 $hidden 条未展开',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change});

  final SyncLogChange change;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = change.title.isEmpty ? change.key : change.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            LibraryTypeBadge(type: change.type, dense: true),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        for (final field in change.fields)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '${_fieldLabel(field.field)}：${field.before} → ${field.after}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

String _fieldLabel(String field) => switch (field) {
  'title' => '书名',
  'author' => '作者',
  'cover' => '封面',
  'intro' => '简介',
  'episodeCount' => '集数',
  'progress' => '进度',
  'shelf' => '收藏',
  _ => field,
};

String _summary(SyncLogRun run) {
  if (run.outcome == SyncOutcome.failed) {
    return switch (run.phase) {
      'config' => '配置校验失败',
      'dir' => '创建目录失败',
      'get' => '拉取失败',
      'parse' => '云端格式不合法',
      'merge' => '合并失败',
      'put' => '上传失败',
      'meta' => '写入本地元数据失败',
      _ => '同步失败',
    };
  }
  if (run.outcome == SyncOutcome.skipped) return '无变化，已跳过';
  if (run.uploaded && run.pulledTotal > 0) {
    return '↑${run.pushedTotal} ↓${run.pulledTotal}';
  }
  if (run.uploaded) return '↑${run.pushedTotal}';
  if (run.pulledTotal > 0) return '↓${run.pulledTotal}';
  if (run.pushedTotal > 0) return '↑${run.pushedTotal}';
  return '无变化';
}

String _durationLabel(int ms) {
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

String _timeLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _dayLabel(DateTime day) {
  final now = DateTime.now();
  if (_sameDay(day, now)) return '今天';
  final yesterday = now.subtract(const Duration(days: 1));
  if (_sameDay(day, yesterday)) return '昨天';
  return '${day.month} 月 ${day.day} 日';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _deviceLabel(String deviceId) {
  if (deviceId.length <= 6) return deviceId;
  return '${deviceId.substring(0, 6)}…';
}
