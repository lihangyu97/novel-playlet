import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_book_store.dart';
import '../../core/storage/offline/offline_paths.dart';
import '../../core/storage/offline/offline_series.dart';
import '../../core/storage/offline/offline_series_store.dart';
import 'offline_downloader.dart';
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

/// 小说离线列表（管理页用；只读 manifest，不扫盘）。
final offlineNovelListProvider = FutureProvider<List<OfflineBookSummary>>(
  (ref) => ref.watch(offlineBookStoreProvider).summaries(),
);

/// 短剧离线列表（管理页用）。
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
