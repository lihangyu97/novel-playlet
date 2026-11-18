import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/log_timeline.dart';
import '../../app/widgets/states.dart';
import '../../core/diagnostics/diagnostic_log.dart';

/// 运行日志：接口报错与不符合预期的事件，按时间倒序。
///
/// 数据在 `<AppSupport>/app-log.json`，只在本机；入口是设置 → 诊断 →「运行日志」。
/// 和同步记录一样按天分组，展开后能看到请求上下文或异常堆栈，可直接复制。
class AppLogPage extends ConsumerWidget {
  const AppLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(diagnosticLogEntriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          entries.maybeWhen(
            data: (items) => items.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空日志',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _clear(context, ref),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: entries.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          message: '读取运行日志失败',
          onRetry: () => ref.invalidate(diagnosticLogEntriesProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyView(
              message: '还没有日志',
              icon: Icons.receipt_long_outlined,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '接口报错与不符合预期的事件，只保存在本机（最多 300 条）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final entry = items[index];
                    final previous = index == 0 ? null : items[index - 1];
                    final showDay =
                        previous == null ||
                        !isSameCalendarDay(previous.atTime, entry.atTime);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showDay) LogDayHeader(day: entry.atTime),
                        _EntryTile(entry: entry),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空运行日志？'),
        content: const Text('只删除本机的诊断日志，不影响书架和同步数据。'),
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
    if (confirmed != true || !context.mounted) return;
    await ref.read(diagnosticLogStoreProvider).clear();
    // 清空是异步的；期间用户可能已经返回，避免对已销毁的 ref 做 invalidate。
    if (!context.mounted) return;
    ref.invalidate(diagnosticLogEntriesProvider);
    showAppSnackBar(context, '已清空运行日志');
  }
}

class _EntryTile extends StatefulWidget {
  const _EntryTile({required this.entry});

  final DiagnosticEntry entry;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entry = widget.entry;
    final failed = entry.level == LogLevel.error;
    final color = failed ? scheme.error : scheme.tertiary;
    final icon = failed
        ? Icons.error_outline_rounded
        : Icons.report_problem_outlined;
    final hasDetail = entry.detail != null;
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      logTimeLabel(entry.atTime),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 17, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.message,
                      maxLines: _expanded ? null : 2,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: failed ? scheme.error : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (entry.count > 1) ...[
                    const SizedBox(width: 8),
                    Text(
                      '×${entry.count}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
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
              if (_expanded && entry.detail != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 69),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_fullTime(entry.atTime)} · '
                              '${_sourceLabel(entry.source)} · '
                              '${_levelLabel(entry.level)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          IconButton(
                            tooltip: '复制这条日志',
                            icon: const Icon(Icons.copy_all_outlined, size: 18),
                            onPressed: () => _copy(context, entry),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            visualDensity: VisualDensity.compact,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      SelectableText(
                        entry.detail!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
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

  Future<void> _copy(BuildContext context, DiagnosticEntry entry) async {
    final text = [
      '${_fullTime(entry.atTime)} ${_levelLabel(entry.level)} '
          '${_sourceLabel(entry.source)}',
      entry.message,
      if (entry.detail != null) entry.detail!,
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showAppSnackBar(context, '已复制日志');
  }
}

String _sourceLabel(DiagnosticSource source) => switch (source) {
  DiagnosticSource.api => '接口',
  DiagnosticSource.app => '应用',
};

String _levelLabel(LogLevel level) => switch (level) {
  LogLevel.error => '报错',
  LogLevel.unexpected => '意外',
};

String _fullTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
