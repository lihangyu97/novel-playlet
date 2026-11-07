import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../core/cache/app_cache.dart' show formatBytes;
import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_series.dart';
import '../../data/models/chapter.dart';
import '../mine/widgets/mine_relative_time.dart';
import 'cache_providers.dart';
import 'offline_downloader.dart';
import 'offline_queue.dart';
import 'offline_task.dart';

/// 离线缓存管理页：小说 / 短剧两个独立 pinned 区的列表、进度、删除。
///
/// 与「设置 → 存储」里的自动缓存不同：这里的文件**永不自动清理**，只有用户
/// 在本页显式删除（单条 / 清空本区）才会释放。两个区互不影响。
class OfflineCachePage extends StatelessWidget {
  const OfflineCachePage({super.key, this.initialKind = OfflineTaskKind.novel});

  /// 打开时落在哪个 tab（从设置页的两个入口进来时区分）。
  final OfflineTaskKind initialKind;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialKind == OfflineTaskKind.novel ? 0 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('离线缓存'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '小说'),
              Tab(text: '短剧'),
            ],
          ),
        ),
        body: const SafeArea(
          top: false,
          child: TabBarView(children: [_NovelTab(), _VideoTab()]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小说 tab
// ---------------------------------------------------------------------------

class _NovelTab extends ConsumerStatefulWidget {
  const _NovelTab();

  @override
  ConsumerState<_NovelTab> createState() => _NovelTabState();
}

class _NovelTabState extends ConsumerState<_NovelTab> {
  @override
  void initState() {
    super.initState();
    // 进入管理页时自愈一次：按文件存在校正 manifest、清掉崩溃残留的 .part 与
    // 无 manifest 的孤立目录。失败不阻断列表（统计略偏小而已）。
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    try {
      final store = ref.read(offlineBookStoreProvider);
      for (final summary in await store.summaries()) {
        await store.reconcile(summary.bookId);
      }
      await store.pruneOrphans();
      await store.cleanupPartFiles();
      if (!mounted) return;
      _invalidate();
    } catch (error) {
      debugPrint('[offline] novel reconcile failed: $error');
    }
  }

  void _invalidate() {
    ref.invalidate(offlineNovelListProvider);
    ref.invalidate(offlineNovelStatsProvider);
    ref.invalidate(offlineNovelProvider);
  }

  Future<void> _continue(OfflineBookSummary summary) async {
    final book = await ref.read(offlineBookStoreProvider).read(summary.bookId);
    if (book == null || !mounted) return;
    try {
      final disposition = await ref
          .read(offlineDownloaderProvider.notifier)
          .startNovelBook(
            bookId: book.bookId,
            title: book.title,
            cover: book.cover,
            chapters: [
              for (final chapter in book.chapters)
                Chapter(
                  id: chapter.id,
                  title: chapter.title,
                  volumeName: chapter.volumeName,
                  index: chapter.index,
                ),
            ],
          );
      if (mounted) _showQueuedHint(context, disposition);
    } catch (error) {
      if (mounted) _showStartError(context, error);
    }
  }

  Future<void> _delete(OfflineBookSummary summary) async {
    final confirmed = await _confirm(
      context,
      title: '删除离线缓存？',
      message:
          '将删除《${summary.title}》已缓存的 ${summary.completed}/${summary.total} 章'
          '（${formatBytes(summary.bytes)}）。删除后需要重新下载。',
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(offlineDownloaderProvider.notifier)
        .clearFor(OfflineTaskKind.novel, summary.bookId);
    await ref.read(offlineBookStoreProvider).delete(summary.bookId);
    if (!mounted) return;
    _invalidate();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除《${summary.title}》的离线缓存')));
  }

  Future<void> _clearAll(int totalBytes) async {
    final confirmed = await _confirm(
      context,
      title: '清空小说离线缓存？',
      message:
          '将删除全部离线小说（共 ${formatBytes(totalBytes)}），短剧离线缓存不受影响。'
          '删除后需要重新下载。',
    );
    if (confirmed != true || !mounted) return;
    final task = ref.read(offlineTaskProvider);
    if (task?.kind == OfflineTaskKind.novel) {
      await ref
          .read(offlineDownloaderProvider.notifier)
          .clearFor(OfflineTaskKind.novel, task!.id);
    }
    await ref.read(offlineBookStoreProvider).clearAll();
    if (!mounted) return;
    _invalidate();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清空小说离线缓存')));
  }

  @override
  Widget build(BuildContext context) {
    return _OfflineTabScaffold<OfflineBookSummary>(
      emptyMessage: '还没有离线缓存的小说\n在小说详情页点「离线缓存」即可整本下载',
      emptyIcon: Icons.menu_book_outlined,
      statsAsync: ref.watch(offlineNovelStatsProvider),
      listAsync: ref.watch(offlineNovelListProvider),
      onClearAll: _clearAll,
      tileBuilder: (context, summary) => _OfflineItemTile(
        cover: summary.cover,
        title: summary.title,
        progressLabel: '已缓存 ${summary.completed}/${summary.total} 章',
        bytes: summary.bytes,
        updatedAt: summary.updatedAt,
        taskProgress: _progressOf(summary.bookId),
        onContinue: summary.completed < summary.total
            ? () => _continue(summary)
            : null,
        onDelete: () => _delete(summary),
      ),
    );
  }

  _TaskProgress? _progressOf(String bookId) {
    final task = ref.watch(offlineTaskProvider);
    if (task == null ||
        task.kind != OfflineTaskKind.novel ||
        task.id != bookId) {
      return null;
    }
    return _TaskProgress(
      completed: task.completed,
      total: task.total,
      status: task.status,
      error: task.error,
    );
  }
}

// ---------------------------------------------------------------------------
// 短剧 tab
// ---------------------------------------------------------------------------

class _VideoTab extends ConsumerStatefulWidget {
  const _VideoTab();

  @override
  ConsumerState<_VideoTab> createState() => _VideoTabState();
}

class _VideoTabState extends ConsumerState<_VideoTab> {
  @override
  void initState() {
    super.initState();
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    try {
      final store = ref.read(offlineSeriesStoreProvider);
      for (final summary in await store.summaries()) {
        await store.reconcile(summary.seriesId);
      }
      await store.pruneOrphans();
      await store.cleanupPartFiles();
      if (!mounted) return;
      _invalidate();
    } catch (error) {
      debugPrint('[offline] video reconcile failed: $error');
    }
  }

  void _invalidate() {
    ref.invalidate(offlineVideoListProvider);
    ref.invalidate(offlineVideoStatsProvider);
    ref.invalidate(offlineSeriesProvider);
  }

  Future<void> _continue(OfflineSeriesSummary summary) async {
    final series = await ref
        .read(offlineSeriesStoreProvider)
        .read(summary.seriesId);
    if (series == null || !mounted) return;
    try {
      final disposition = await ref
          .read(offlineDownloaderProvider.notifier)
          .startVideoSeries(
            seriesId: series.seriesId,
            title: series.title,
            cover: series.cover,
            episodes: [
              for (final episode in series.episodes)
                Chapter(
                  id: episode.id,
                  title: episode.title,
                  index: episode.index,
                ),
            ],
          );
      if (mounted) _showQueuedHint(context, disposition);
    } catch (error) {
      if (mounted) _showStartError(context, error);
    }
  }

  Future<void> _delete(OfflineSeriesSummary summary) async {
    final confirmed = await _confirm(
      context,
      title: '删除离线缓存？',
      message:
          '将删除《${summary.title}》已缓存的 ${summary.completed}/${summary.total} 集'
          '（${formatBytes(summary.bytes)}）。删除后需要重新下载。',
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(offlineDownloaderProvider.notifier)
        .clearFor(OfflineTaskKind.video, summary.seriesId);
    await ref.read(offlineSeriesStoreProvider).delete(summary.seriesId);
    if (!mounted) return;
    _invalidate();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除《${summary.title}》的离线缓存')));
  }

  Future<void> _clearAll(int totalBytes) async {
    final confirmed = await _confirm(
      context,
      title: '清空短剧离线缓存？',
      message:
          '将删除全部离线短剧（共 ${formatBytes(totalBytes)}），小说离线缓存不受影响。'
          '删除后需要重新下载。',
    );
    if (confirmed != true || !mounted) return;
    final task = ref.read(offlineTaskProvider);
    if (task?.kind == OfflineTaskKind.video) {
      await ref
          .read(offlineDownloaderProvider.notifier)
          .clearFor(OfflineTaskKind.video, task!.id);
    }
    await ref.read(offlineSeriesStoreProvider).clearAll();
    if (!mounted) return;
    _invalidate();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已清空短剧离线缓存')));
  }

  @override
  Widget build(BuildContext context) {
    return _OfflineTabScaffold<OfflineSeriesSummary>(
      emptyMessage: '还没有离线缓存的短剧\n在短剧详情页点「离线缓存」即可整剧下载',
      emptyIcon: Icons.movie_outlined,
      statsAsync: ref.watch(offlineVideoStatsProvider),
      listAsync: ref.watch(offlineVideoListProvider),
      onClearAll: _clearAll,
      tileBuilder: (context, summary) => _OfflineItemTile(
        cover: summary.cover,
        title: summary.title,
        progressLabel: '已缓存 ${summary.completed}/${summary.total} 集',
        bytes: summary.bytes,
        updatedAt: summary.updatedAt,
        taskProgress: _progressOf(summary.seriesId),
        onContinue: summary.completed < summary.total
            ? () => _continue(summary)
            : null,
        onDelete: () => _delete(summary),
      ),
    );
  }

  _TaskProgress? _progressOf(String seriesId) {
    final task = ref.watch(offlineTaskProvider);
    if (task == null ||
        task.kind != OfflineTaskKind.video ||
        task.id != seriesId) {
      return null;
    }
    return _TaskProgress(
      completed: task.completed,
      total: task.total,
      status: task.status,
      error: task.error,
    );
  }
}

// ---------------------------------------------------------------------------
// 共用骨架 / 组件
// ---------------------------------------------------------------------------

class _TaskProgress {
  const _TaskProgress({
    required this.completed,
    required this.total,
    required this.status,
    this.error,
  });

  final int completed;
  final int total;
  final OfflineTaskStatus status;

  /// 暂停/失败时的原因（如「2 章失败」「空间不足…」），展示在状态下方。
  final String? error;

  double get ratio => total <= 0 ? 0 : (completed / total).clamp(0, 1);

  bool get active => status == OfflineTaskStatus.running;
}

class _OfflineTabScaffold<T> extends StatelessWidget {
  const _OfflineTabScaffold({
    required this.emptyMessage,
    required this.emptyIcon,
    required this.statsAsync,
    required this.listAsync,
    required this.onClearAll,
    required this.tileBuilder,
  });

  final String emptyMessage;
  final IconData emptyIcon;
  final AsyncValue<OfflineStats> statsAsync;
  final AsyncValue<List<T>> listAsync;
  final Future<void> Function(int totalBytes) onClearAll;
  final Widget Function(BuildContext context, T item) tileBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return listAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: ErrorView(message: '读取离线缓存失败', onRetry: () {}),
      ),
      data: (list) {
        if (list.isEmpty) {
          return EmptyView(message: emptyMessage, icon: emptyIcon);
        }
        return ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            _SectionHeader(
              stats: statsAsync.value,
              statsError: statsAsync.hasError,
              onClearAll: onClearAll,
            ),
            for (final item in list)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: tileBuilder(context, item),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Text(
                '离线缓存不会被自动清理，只有在这里手动删除才会释放空间。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.stats,
    required this.statsError,
    required this.onClearAll,
  });

  final OfflineStats? stats;
  final bool statsError;
  final Future<void> Function(int totalBytes) onClearAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = stats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      value == null
                          ? (statsError ? '占用统计失败' : '正在统计占用…')
                          : '${value.count} 个 · ${formatBytes(value.bytes)}'
                                ' / 上限 ${formatBytes(value.capBytes)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: value == null || value.bytes <= 0
                        ? null
                        : () => onClearAll(value.bytes),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('清空本区'),
                  ),
                ],
              ),
              if (value != null) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: value.usedRatio,
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        value.isOverCap ? scheme.error : scheme.primary,
                      ),
                    ),
                  ),
                ),
                if (value.isOverCap) ...[
                  const SizedBox(height: 8),
                  Text(
                    '已超过本区上限，新的下载会被阻止，请先清理。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineItemTile extends StatelessWidget {
  const _OfflineItemTile({
    required this.cover,
    required this.title,
    required this.progressLabel,
    required this.bytes,
    required this.updatedAt,
    required this.taskProgress,
    required this.onContinue,
    required this.onDelete,
  });

  final String cover;
  final String title;
  final String progressLabel;
  final int bytes;
  final DateTime updatedAt;
  final _TaskProgress? taskProgress;
  final Future<void> Function()? onContinue;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = taskProgress;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NovelCover(
          url: cover,
          width: 48,
          height: 48 * kCoverAspect,
          radius: 8,
          fadeInDuration: Duration.zero,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$progressLabel · ${formatBytes(bytes)} · '
                '${mineRelativeTime(updatedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.ratio,
                    minHeight: 5,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                if (progress.error != null &&
                    progress.status != OfflineTaskStatus.running) ...[
                  const SizedBox(height: 4),
                  Text(
                    progress.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 2),
              Row(
                children: [
                  if (progress != null)
                    Text(
                      offlineTaskStatusLabel(progress.status),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: progress.status == OfflineTaskStatus.failed
                            ? scheme.error
                            : scheme.primary,
                      ),
                    )
                  else if (onContinue != null)
                    TextButton(
                      onPressed: () => onContinue!(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                      ),
                      child: const Text('继续缓存'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => onDelete(),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.error,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

void _showStartError(BuildContext context, Object error) {
  final message = switch (error) {
    OfflineQuotaExceeded() =>
      '离线缓存已满：已用 ${formatBytes(error.usedBytes)}'
          ' / 上限 ${formatBytes(error.capBytes)}，请先到「设置 → 存储」清理。',
    OfflineQueueFullException() =>
      '缓存队列已满（最多 ${error.maxLength} 个），请先等前面的任务完成。',
    _ => '开始下载失败，请重试',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// start* 返回 queued 时给用户回执：单任务下载器正跑别的任务，本次点击只是
/// 入队，不会立刻开始。
void _showQueuedHint(
  BuildContext context,
  OfflineStartDisposition disposition,
) {
  if (disposition != OfflineStartDisposition.queued) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('已加入缓存队列，等前面的任务完成后自动开始')));
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
}
