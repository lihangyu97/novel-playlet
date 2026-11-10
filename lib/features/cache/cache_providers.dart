import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_book_store.dart';
import '../../core/storage/offline/offline_paths.dart';
import '../../core/storage/offline/offline_series.dart';
import '../../core/storage/offline/offline_series_store.dart';
import 'offline_downloader.dart';
import 'offline_queue.dart';
import 'offline_task.dart';

/// 离线区的路径/存储/下载器/统计 providers。
///
/// 注意：这是**手动清理**的 pinned 区，与自动缓存（AppCache/ReaderChapterCache）
/// 完全隔离；这里的 provider 只读离线目录，不参与任何自动淘汰。

/// 离线区路径（默认 `<Application Support>/offline`，测试可 override）。
final offlinePathsProvider = Provider<OfflinePaths>((ref) => OfflinePaths());

/// 小说离线区存储。
final offlineBookStoreProvider = Provider<OfflineBookStore>(
  (ref) => OfflineBookStore(paths: ref.watch(offlinePathsProvider)),
);

/// 短剧离线区存储。
final offlineSeriesStoreProvider = Provider<OfflineSeriesStore>(
  (ref) => OfflineSeriesStore(paths: ref.watch(offlinePathsProvider)),
);

/// 单任务状态持久化（SharedPreferences `offline_task_v1`）。
final offlineTaskStoreProvider = Provider<OfflineTaskStore>(
  (ref) => OfflineTaskStore(),
);

/// 下载节奏参数（测试可覆写成 0 时长让用例瞬时完成）。
final offlineDownloadSettingsProvider = Provider<OfflineDownloadSettings>(
  (ref) => const OfflineDownloadSettings(),
);

/// 下载器网络动作（生产走 ApiClient；测试 override 成内存 fake）。
final offlineNetworkProvider = Provider<OfflineNetwork>(
  (ref) => ApiOfflineNetwork(ref.watch(apiClientProvider)),
);

/// 进程级单任务下载器（小说整本 / 短剧整剧共用）。
final offlineDownloaderProvider =
    NotifierProvider<OfflineDownloader, OfflineTask?>(OfflineDownloader.new);

/// 离线下载队列（当前任务完成后自动启动队列里的下一个；只在内存里）。
final offlineQueueProvider =
    NotifierProvider<OfflineQueue, List<OfflineQueuedTask>>(OfflineQueue.new);

/// 只读当前任务快照（页面展示进度/状态用）。
final offlineTaskProvider = Provider<OfflineTask?>(
  (ref) => ref.watch(offlineDownloaderProvider),
);

/// 小说离线区统计（本数 / 字节 / 上限）。
final offlineNovelStatsProvider = FutureProvider<OfflineStats>(
  (ref) => ref.watch(offlineBookStoreProvider).stats(),
);

/// 短剧离线区统计（部数 / 字节 / 上限）。
final offlineVideoStatsProvider = FutureProvider<OfflineStats>(
  (ref) => ref.watch(offlineSeriesStoreProvider).stats(),
);

/// 小说离线列表（缓存中心用；只读 manifest，不扫盘）。
final offlineNovelListProvider = FutureProvider<List<OfflineBookSummary>>(
  (ref) => ref.watch(offlineBookStoreProvider).summaries(),
);

/// 短剧离线列表（缓存中心用）。
final offlineVideoListProvider = FutureProvider<List<OfflineSeriesSummary>>(
  (ref) => ref.watch(offlineSeriesStoreProvider).summaries(),
);

/// 某本书的离线 manifest；页面用它判断"是否已缓存 / 离线兜底"。
final offlineNovelProvider = FutureProvider.family<OfflineBook?, String>(
  (ref, bookId) => ref.watch(offlineBookStoreProvider).read(bookId),
);

/// 某部剧的离线 manifest。
final offlineSeriesProvider = FutureProvider.family<OfflineSeries?, String>(
  (ref, seriesId) => ref.watch(offlineSeriesStoreProvider).read(seriesId),
);

/// 一个离线条目（小说 / 短剧）的三态。
enum OfflineEntryStatus { none, inProgress, cached }

/// 离线条目的缓存状态，`(kind, id)` 为键。
///
/// 状态以离线区 manifest 为准（进程重启后仍正确），进行中还要看当前任务与
/// 等待队列。详情页 OfflineDownloadButton 与阅读页顶部「缓存小说」共用这
/// 一份判定，避免两处各写一套后漂移。
final offlineEntryStatusProvider = Provider.autoDispose
    .family<OfflineEntryStatus, ({OfflineTaskKind kind, String id})>((
      ref,
      entry,
    ) {
      final int cachedTotal;
      final int cachedCompleted;
      switch (entry.kind) {
        case OfflineTaskKind.novel:
          final manifest = ref.watch(offlineNovelProvider(entry.id)).value;
          cachedTotal = manifest?.total ?? 0;
          cachedCompleted = manifest?.completed ?? 0;
        case OfflineTaskKind.video:
          final manifest = ref.watch(offlineSeriesProvider(entry.id)).value;
          cachedTotal = manifest?.total ?? 0;
          cachedCompleted = manifest?.completed ?? 0;
      }
      // 已下载完整：manifest 完整或任务已完成（manifest provider 可能还没刷新）。
      if (cachedTotal > 0 && cachedCompleted >= cachedTotal) {
        return OfflineEntryStatus.cached;
      }
      final task = ref.watch(offlineDownloaderProvider);
      final active =
          task != null && task.kind == entry.kind && task.id == entry.id;
      if (active && task.isDone) return OfflineEntryStatus.cached;
      final queued = ref
          .watch(offlineQueueProvider)
          .any((job) => job.kind == entry.kind && job.id == entry.id);
      // 任务失败会回到 none（可重新 start，按文件缺口续传）；没有活动任务但
      // manifest 只完成一部分（取消/重启残留）算进行中，交给缓存中心继续。
      final inProgress =
          queued ||
          (active
              ? (task.isRunning || task.isPaused)
              : (cachedTotal > 0 && cachedCompleted > 0));
      return inProgress
          ? OfflineEntryStatus.inProgress
          : OfflineEntryStatus.none;
    });
