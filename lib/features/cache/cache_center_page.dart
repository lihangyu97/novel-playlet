import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../core/cache/app_cache.dart' show formatBytes;
import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_series.dart';
import '../../data/models/chapter.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';
import 'cache_providers.dart';
import 'offline_queue.dart';
import 'offline_downloader.dart';
import 'offline_task.dart';

/// 缓存中心：从「我的」右下角悬浮缓存按钮进入，按小说 / 短剧分区列出正在下载、
/// 排队中与已下载的内容（进度条 + 网速），点条目 Hero 飞进对应详情页。
///
/// 与设置页的「离线缓存管理页」（[OfflineCachePage]）分工：那边负责删除/清空
/// 等管理动作；本页只做浏览与下载控制（暂停 / 继续 / 重试），不提供删除。
class CacheCenterPage extends ConsumerStatefulWidget {
  const CacheCenterPage({super.key});

  @override
  ConsumerState<CacheCenterPage> createState() => _CacheCenterPageState();
}

class _CacheCenterPageState extends ConsumerState<CacheCenterPage> {
  @override
  void initState() {
    super.initState();
    // 进页面刷新一次列表：这两个 provider 是进程级缓存，上次下载完成时页面
    // 不一定还活着，重进时要以磁盘上的 manifest 为准重新读一遍。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _invalidateLists();
    });
  }

  void _invalidateLists() {
    ref.invalidate(offlineNovelListProvider);
    ref.invalidate(offlineVideoListProvider);
  }

  @override
  Widget build(BuildContext context) {
    // 任务到达终态时刷新列表：完成/暂停/失败都可能改动 manifest 的
    // completed/bytes，列表不刷新就会停在旧数字上。
    ref.listen(offlineDownloaderProvider, (previous, next) {
      final status = next?.status;
      if (status == OfflineTaskStatus.done ||
          status == OfflineTaskStatus.paused ||
          status == OfflineTaskStatus.failed) {
        _invalidateLists();
      }
    });

    final novelList = ref.watch(offlineNovelListProvider);
    final videoList = ref.watch(offlineVideoListProvider);
    final task = ref.watch(offlineTaskProvider);
    final queue = ref.watch(offlineQueueProvider);

    final novelEntries = _entriesFor(
      downloaded: [
        for (final summary in novelList.value ?? const <OfflineBookSummary>[])
          _CacheEntry.fromBook(summary),
      ],
      active: task,
      queue: queue,
      sectionKind: OfflineTaskKind.novel,
    );
    final videoEntries = _entriesFor(
      downloaded: [
        for (final summary in videoList.value ?? const <OfflineSeriesSummary>[])
          _CacheEntry.fromSeries(summary),
      ],
      active: task,
      queue: queue,
      sectionKind: OfflineTaskKind.video,
    );

    final loading =
        novelEntries.isEmpty &&
        videoEntries.isEmpty &&
        (novelList.isLoading || videoList.isLoading);
    final failed =
        novelEntries.isEmpty &&
        videoEntries.isEmpty &&
        (novelList.hasError || videoList.hasError);

    return Scaffold(
      appBar: AppBar(title: const Text('缓存')),
      body: SafeArea(
        top: false,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : failed
            ? ErrorView(message: '读取缓存列表失败', onRetry: _invalidateLists)
            : novelEntries.isEmpty && videoEntries.isEmpty
            ? const EmptyView(
                message: '还没有下载内容\n在详情页点「缓存」即可整本/整剧下载',
                icon: Icons.download_outlined,
              )
            : ListView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 28),
                children: [
                  if (novelEntries.isNotEmpty) ...[
                    const _SectionTitle(title: '小说'),
                    for (final entry in novelEntries) _tile(entry),
                  ],
                  if (videoEntries.isNotEmpty) ...[
                    const _SectionTitle(title: '短剧'),
                    for (final entry in videoEntries) _tile(entry),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _tile(_CacheEntry entry) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: _CacheTile(
        entry: entry,
        onTap: () => _openDetail(entry),
        onPause: _pause,
        onContinue: () => _continue(entry),
        onRetry: () => _retry(entry),
        onCancelQueued: () => _cancelQueued(entry),
      ),
    );
  }

  /// 把一个分区的展示数据合成成一条列表：活动任务 → 排队中 → 已下载。
  ///
  /// - 活动任务用实时 completed/total/bytes/status/speed 覆盖 manifest 快照；
  /// - 排队条目按队列顺序排在活动任务之后、已下载之前，同 id 的 manifest 用于
  ///   补充「已缓存 x/y」这类已有进度；
  /// - 同一 id 只出现一次，否则同一路由里会出现重复 Hero tag 直接断言。
  ///
  /// 只合并与 [sectionKind] 同类型的任务/队列条目：一个小说任务不能同时出现在
  /// 小说和短剧分区。
  List<_CacheEntry> _entriesFor({
    required List<_CacheEntry> downloaded,
    required OfflineTask? active,
    required List<OfflineQueuedTask> queue,
    required OfflineTaskKind sectionKind,
  }) {
    final remaining = <String, _CacheEntry>{
      for (final entry in downloaded) entry.id: entry,
    };
    final entries = <_CacheEntry>[];

    if (active != null && active.kind == sectionKind) {
      entries.add(
        _CacheEntry.fromTask(active, fallback: remaining.remove(active.id)),
      );
    }
    for (final queued in queue) {
      if (queued.kind != sectionKind) continue;
      // 防御：队列里理论上不会同时有正在跑的那一条，但 UI 不能因此多出一条
      // 同 id 条目（重复 Hero tag）。
      if (entries.any((entry) => entry.id == queued.id)) continue;
      entries.add(
        _CacheEntry.fromQueued(queued, fallback: remaining.remove(queued.id)),
      );
    }
    entries.addAll(remaining.values);
    return entries;
  }

  void _openDetail(_CacheEntry entry) {
    switch (entry.kind) {
      case OfflineTaskKind.novel:
        final heroTag = CoverHeroTag.novel('cache-center', entry.id);
        context.pushAppRoute(
          DetailRoute(
            bookId: entry.id,
            preview: NovelItem(
              id: entry.id,
              title: entry.title,
              cover: entry.cover,
            ),
            heroTag: heroTag,
          ),
        );
      case OfflineTaskKind.video:
        final heroTag = CoverHeroTag.video('cache-center', entry.id);
        context.pushAppRoute(
          VideoDetailRoute(
            seriesId: entry.id,
            preview: VideoSeries(
              id: entry.id,
              title: entry.title,
              cover: entry.cover,
            ),
            heroTag: heroTag,
          ),
        );
    }
  }

  Future<void> _pause() async {
    await ref.read(offlineDownloaderProvider.notifier).pause();
  }

  /// 取消排队：只把这条从队列里摘掉（没开始下，不碰离线区文件）。
  void _cancelQueued(_CacheEntry entry) {
    ref.read(offlineQueueProvider.notifier).remove(entry.kind, entry.id);
  }

  Future<void> _continue(_CacheEntry entry) async {
    try {
      // 本进程内暂停的任务直接接着跑；进程重启后的恢复态没有内存入参，
      // resume() 会返回 false，此时按 manifest 重建入参重新 start（幂等续传）。
      final resumed = await ref
          .read(offlineDownloaderProvider.notifier)
          .resume();
      if (resumed) return;
      await _startFromManifest(entry);
    } catch (error) {
      if (!mounted) return;
      _showStartError(error);
    }
  }

  Future<void> _retry(_CacheEntry entry) async {
    try {
      await _startFromManifest(entry);
    } catch (error) {
      if (!mounted) return;
      _showStartError(error);
    }
  }

  /// 从 manifest 重建完整章节/选集列表再开始下载（start* 按文件缺口续传）。
  Future<void> _startFromManifest(_CacheEntry entry) async {
    final downloader = ref.read(offlineDownloaderProvider.notifier);
    final OfflineStartDisposition disposition;
    switch (entry.kind) {
      case OfflineTaskKind.novel:
        final book = await ref.read(offlineBookStoreProvider).read(entry.id);
        if (book == null || !mounted) return;
        disposition = await downloader.startNovelBook(
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
      case OfflineTaskKind.video:
        final series = await ref
            .read(offlineSeriesStoreProvider)
            .read(entry.id);
        if (series == null || !mounted) return;
        disposition = await downloader.startVideoSeries(
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
    }
    if (disposition == OfflineStartDisposition.queued && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已加入缓存队列，等前面的任务完成后自动开始')));
    }
  }

  /// 下载启动失败的提示文案与管理页保持一致（容量 / 队列满 / 其它）。
  void _showStartError(Object error) {
    final message = switch (error) {
      OfflineQuotaExceeded() =>
        '离线缓存已满：已用 ${formatBytes(error.usedBytes)}'
            ' / 上限 ${formatBytes(error.capBytes)}，请先到「设置 → 存储」清理。',
      OfflineQueueFullException() =>
        '缓存队列已满（最多 ${error.maxLength} 个），请先等前面的任务完成。',
      _ => '开始下载失败，请重试',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 分区标题「小说 / 短剧」。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 条目展示状态：任务四态之外，多了「已下载但有缺口、当前没有任务」的 partial
/// 与「在下载队列里等待」的 queued。
enum _EntryStatus { running, paused, failed, done, partial, queued }

/// 一条缓存记录（已下载 manifest 或活动任务）。
class _CacheEntry {
  const _CacheEntry({
    required this.kind,
    required this.id,
    required this.title,
    required this.cover,
    required this.completed,
    required this.total,
    required this.bytes,
    required this.status,
    this.speedBytesPerSecond = 0,
    this.error,
  });

  factory _CacheEntry.fromBook(OfflineBookSummary summary) => _CacheEntry(
    kind: OfflineTaskKind.novel,
    id: summary.bookId,
    title: summary.title,
    cover: summary.cover,
    completed: summary.completed,
    total: summary.total,
    bytes: summary.bytes,
    status: summary.total > 0 && summary.completed >= summary.total
        ? _EntryStatus.done
        : _EntryStatus.partial,
  );

  factory _CacheEntry.fromSeries(OfflineSeriesSummary summary) => _CacheEntry(
    kind: OfflineTaskKind.video,
    id: summary.seriesId,
    title: summary.title,
    cover: summary.cover,
    completed: summary.completed,
    total: summary.total,
    bytes: summary.bytes,
    status: summary.total > 0 && summary.completed >= summary.total
        ? _EntryStatus.done
        : _EntryStatus.partial,
  );

  /// 排队中条目：标题/封面以队列快照为准，进度沿用已有 manifest（如有）。
  factory _CacheEntry.fromQueued(
    OfflineQueuedTask queued, {
    _CacheEntry? fallback,
  }) => _CacheEntry(
    kind: queued.kind,
    id: queued.id,
    title: queued.title.isNotEmpty ? queued.title : (fallback?.title ?? ''),
    cover: queued.cover.isNotEmpty ? queued.cover : (fallback?.cover ?? ''),
    completed: fallback?.completed ?? 0,
    total: fallback?.total ?? 0,
    bytes: fallback?.bytes ?? 0,
    status: _EntryStatus.queued,
  );

  /// 用活动任务的实时数据覆盖 manifest 快照（任务缺失的字段退回 [fallback]）。
  factory _CacheEntry.fromTask(OfflineTask task, {_CacheEntry? fallback}) =>
      _CacheEntry(
        kind: task.kind,
        id: task.id,
        title: task.title.isNotEmpty ? task.title : (fallback?.title ?? ''),
        cover: task.cover.isNotEmpty ? task.cover : (fallback?.cover ?? ''),
        completed: task.completed,
        total: task.total > 0 ? task.total : (fallback?.total ?? 0),
        bytes: task.bytes,
        status: switch (task.status) {
          OfflineTaskStatus.running => _EntryStatus.running,
          OfflineTaskStatus.failed => _EntryStatus.failed,
          OfflineTaskStatus.done => _EntryStatus.done,
          OfflineTaskStatus.idle ||
          OfflineTaskStatus.paused => _EntryStatus.paused,
        },
        speedBytesPerSecond: task.speedBytesPerSecond,
        error: task.error,
      );

  final OfflineTaskKind kind;
  final String id;
  final String title;
  final String cover;
  final int completed;
  final int total;
  final int bytes;
  final _EntryStatus status;

  /// 运行中才有的实时网速（字节/秒），由下载器采样。
  final int speedBytesPerSecond;

  /// 暂停/失败原因。
  final String? error;

  double get ratio =>
      total <= 0 ? 0 : (completed / total).clamp(0, 1).toDouble();

  int get percent => (ratio * 100).round();

  /// 章 / 集（小说与短剧的进度单位不同）。
  String get unit => kind == OfflineTaskKind.novel ? '章' : '集';
}

/// 单条缓存记录：封面 + 标题 + 状态行 + 进度条 + 右侧下载动作。
class _CacheTile extends StatelessWidget {
  const _CacheTile({
    required this.entry,
    required this.onTap,
    required this.onPause,
    required this.onContinue,
    required this.onRetry,
    required this.onCancelQueued,
  });

  final _CacheEntry entry;
  final VoidCallback onTap;
  final VoidCallback onPause;
  final VoidCallback onContinue;
  final VoidCallback onRetry;
  final VoidCallback onCancelQueued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final heroTag = entry.kind == OfflineTaskKind.novel
        ? CoverHeroTag.novel('cache-center', entry.id)
        : CoverHeroTag.video('cache-center', entry.id);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverHero(
                tag: heroTag,
                child: NovelCover(
                  url: entry.cover,
                  width: 48,
                  height: 48 * kCoverAspect,
                  radius: 8,
                  fadeInDuration: Duration.zero,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _statusLine(entry),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: entry.status == _EntryStatus.failed
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: entry.ratio,
                        minHeight: 5,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    if (_reasonOf(entry) case final reason?) ...[
                      const SizedBox(height: 4),
                      Text(
                        reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_actionOf() case final action?) ...[
                const SizedBox(width: 4),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(_CacheEntry entry) => switch (entry.status) {
    _EntryStatus.running =>
      '下载中 ${entry.percent}%'
          '${entry.speedBytesPerSecond > 0 ? ' · ${formatBytes(entry.speedBytesPerSecond)}/s' : ''}'
          ' · ${formatBytes(entry.bytes)}',
    _EntryStatus.paused =>
      '已暂停 ${entry.percent}% · ${formatBytes(entry.bytes)}',
    _EntryStatus.failed =>
      '下载失败${entry.error == null ? '' : ' · ${entry.error}'}',
    _EntryStatus.done || _EntryStatus.partial =>
      '已缓存 ${entry.completed}/${entry.total} ${entry.unit}'
          ' · ${formatBytes(entry.bytes)}',
    _EntryStatus.queued =>
      '排队中'
          '${entry.total > 0 && entry.completed > 0 ? ' · 已缓存 ${entry.completed}/${entry.total} ${entry.unit}' : ''}'
          ' · 等前面的任务完成后自动开始',
  };

  /// 暂停原因单独一行（失败原因已并进状态行，按需求里的状态行示例口径）。
  String? _reasonOf(_CacheEntry entry) =>
      entry.status == _EntryStatus.paused ? entry.error : null;

  Widget? _actionOf() {
    return switch (entry.status) {
      _EntryStatus.running => IconButton(
        tooltip: '暂停缓存',
        visualDensity: VisualDensity.compact,
        onPressed: onPause,
        icon: const Icon(Icons.pause_circle_outlined),
      ),
      _EntryStatus.paused || _EntryStatus.partial => IconButton(
        tooltip: '继续缓存',
        visualDensity: VisualDensity.compact,
        onPressed: onContinue,
        icon: const Icon(Icons.play_circle_outlined),
      ),
      _EntryStatus.failed => IconButton(
        tooltip: '重试下载',
        visualDensity: VisualDensity.compact,
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
      ),
      _EntryStatus.queued => IconButton(
        tooltip: '取消排队',
        visualDensity: VisualDensity.compact,
        onPressed: onCancelQueued,
        icon: const Icon(Icons.close_rounded),
      ),
      _EntryStatus.done => null,
    };
  }
}
