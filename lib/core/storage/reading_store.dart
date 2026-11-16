import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';
import 'library_db.dart';
import 'library_records.dart';

/// 一本书的阅读进度。
class ReadingProgress {
  const ReadingProgress({
    required this.bookId,
    required this.bookTitle,
    required this.cover,
    required this.chapterId,
    required this.chapterIndex,
    required this.updatedAt,
    this.blockIndex = 0,
  });

  final String bookId;
  final String bookTitle;
  final String cover;
  final String chapterId;
  final int chapterIndex;

  /// 当前页首段在整章段落里的下标（不是页号）。换字号/换设备后靠它重新定位
  /// 到读到的那一段，所以恢复比"第 N 页"稳。旧版本没有该字段，按 0 读。
  final int blockIndex;
  final DateTime updatedAt;
}

/// 一部短剧的观看进度。
class VideoWatchProgress {
  const VideoWatchProgress({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.episodeIndex = 0,
    required this.updatedAt,
  });

  final String seriesId;
  final String title;
  final String cover;

  /// 看到第几集（0-based）。
  final int episodeIndex;
  final DateTime updatedAt;
}

/// 书架 / 收藏 / 进度的门面（SQLite，一张表）。
///
/// 小说与短剧在同一张 `library` 表里，靠 [LibraryType] 区分；书架、历史都由
/// 这张表派生，不再单独存列表。
///
/// 页面只通过这里的 revision 计数感知变更，不要自己去读库。
class ReadingStore {
  /// 小说侧（书架 / 阅读进度）的**聚合**变更计数。跨页面的 UI（如"我的"）
  /// 监听它来刷新，避免引入全局状态管理依赖。
  ///
  /// 写入会同时 bump 更细的 [shelfRevision] / [recentRevision]：只关心其中
  /// 一块的 UI 订阅细分通道。短剧侧同理见 [videoShelfRevision] /
  /// [videoHistoryRevision]。
  final ValueNotifier<int> novelRevision = ValueNotifier<int>(0);

  /// 书架内容变更计数（小说加/移书架）。阅读进度写入不动它。
  final ValueNotifier<int> shelfRevision = ValueNotifier<int>(0);

  /// 最近阅读变更计数：保存阅读进度（含书架内外的书）。
  final ValueNotifier<int> recentRevision = ValueNotifier<int>(0);

  /// 短剧侧（收藏 / 观看进度）的聚合变更计数。
  final ValueNotifier<int> videoRevision = ValueNotifier<int>(0);

  /// 短剧收藏变更计数。
  final ValueNotifier<int> videoShelfRevision = ValueNotifier<int>(0);

  /// 最近观看变更计数。
  final ValueNotifier<int> videoHistoryRevision = ValueNotifier<int>(0);

  /// 小说与短剧**共用**的纯进度行上限（读过但没上过架的行）。
  ///
  /// 书架条目与墓碑不计入、也不淘汰：墓碑是删除能同步出去的唯一依据，删早了
  /// 远端旧值会把条目复活。
  static const int libraryLimit = 500;

  Future<Database> get _db => LibraryDb.instance();

  /// 进程内单调递增的毫秒时间戳。
  ///
  /// LWW 全靠它排序，而 `DateTime.now()` 在同一毫秒内的连续调用会相等——
  /// 快速连点选集/连续翻页时会让"最近观看"顺序和后写覆盖前写都失准。
  int _stamp = 0;

  /// 上一次淘汰（[LibraryDb.prune]）用的时间戳。
  ///
  /// 进度写是高频路径，而 500 条上限极少触顶：每次写都 `COUNT(*)` 没必要，
  /// 两次之间至少隔 [pruneInterval]。行数是先涨后裁，短暂超出上限不影响读。
  int _lastPruneAt = 0;

  static const Duration pruneInterval = Duration(minutes: 1);

  int _now() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _stamp = now > _stamp ? now : _stamp + 1;
    return _stamp;
  }

  // ---------------------------------------------------------------------
  // 统一查询（历史 / 收藏，跨小说与短剧）
  // ---------------------------------------------------------------------

  /// 「历史」：读过且不是墓碑，按最近阅读倒序。`type` 为空时两类混排。
  Future<List<LibraryRecord>> history({
    int limit = 20,
    LibraryType? type,
  }) async {
    return LibraryDb.readHistory(await _db, limit: limit, type: type);
  }

  /// 「收藏」：当前在架条目，按加入时间倒序。`type` 为空时两类混排。
  Future<List<LibraryRecord>> shelfRecords({LibraryType? type}) async {
    return LibraryDb.readShelf(await _db, type: type);
  }

  /// 历史条数（不含墓碑），页头统计用。
  Future<int> historyCount() async => LibraryDb.countHistory(await _db);

  // ---------------------------------------------------------------------
  // 小说
  // ---------------------------------------------------------------------

  Future<bool> isOnShelf(String bookId) async =>
      _isOnShelf(LibraryType.novel, bookId);

  /// 加入书架；已在架上则不重复写入。
  Future<void> addToShelf(NovelItem item) async {
    await _addToShelf(
      LibraryType.novel,
      item.id,
      title: item.title,
      author: item.author,
      cover: item.cover,
      colorDominate: item.colorDominate,
    );
  }

  Future<void> removeFromShelf(String bookId) async =>
      _removeFromShelf(LibraryType.novel, bookId);

  Future<void> saveProgress({
    required String bookId,
    required String bookTitle,
    required String cover,
    required String chapterId,
    required int chapterIndex,
    int blockIndex = 0,
  }) async {
    if (bookId.isEmpty || chapterId.isEmpty) return;
    await _saveProgress(
      LibraryType.novel,
      bookId,
      title: bookTitle,
      cover: cover,
      progressRef: chapterId,
      progressIndex: chapterIndex,
      progressSub: blockIndex,
    );
  }

  Future<ReadingProgress?> progress(String bookId) async {
    final record = await LibraryDb.read(
      await _db,
      LibraryType.novel,
      bookId,
    );
    if (record == null || !record.hasProgress) return null;
    return ReadingProgress(
      bookId: record.sourceId,
      bookTitle: record.title,
      cover: record.cover,
      chapterId: record.progressRef,
      chapterIndex: record.progressIndex,
      blockIndex: record.progressSub,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(record.lastReadAt),
    );
  }

  // ---------------------------------------------------------------------
  // 短剧
  // ---------------------------------------------------------------------

  Future<bool> isVideoOnShelf(String seriesId) async =>
      _isOnShelf(LibraryType.playlet, seriesId);

  /// 加入收藏；已收藏则不重复写入。
  Future<void> addVideoToShelf(VideoSeries item) async {
    await _addToShelf(
      LibraryType.playlet,
      item.id,
      title: item.title,
      cover: item.cover,
      intro: item.intro,
      episodeCount: item.episodeCount,
      colorDominate: item.colorDominate,
    );
  }

  Future<void> removeVideoFromShelf(String seriesId) async =>
      _removeFromShelf(LibraryType.playlet, seriesId);

  /// 记一次观看进度；最近观看由进度派生，不再单独维护列表。
  Future<void> saveVideoProgress({
    required String seriesId,
    required String title,
    String cover = '',
    required int episodeIndex,
  }) async {
    if (seriesId.isEmpty) return;
    await _saveProgress(
      LibraryType.playlet,
      seriesId,
      title: title,
      cover: cover,
      progressIndex: episodeIndex,
    );
  }

  Future<VideoWatchProgress?> videoProgress(String seriesId) async {
    final record = await LibraryDb.read(
      await _db,
      LibraryType.playlet,
      seriesId,
    );
    if (record == null || !record.hasProgress) return null;
    return VideoWatchProgress(
      seriesId: record.sourceId,
      title: record.title,
      cover: record.cover,
      episodeIndex: record.progressIndex,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(record.lastReadAt),
    );
  }

  // ---------------------------------------------------------------------
  // 写路径（两类内容共用）
  // ---------------------------------------------------------------------

  Future<bool> _isOnShelf(LibraryType type, String sourceId) async {
    if (sourceId.isEmpty) return false;
    final record = await LibraryDb.read(await _db, type, sourceId);
    return record?.onShelf ?? false;
  }

  Future<void> _addToShelf(
    LibraryType type,
    String sourceId, {
    required String title,
    String author = '',
    String cover = '',
    String intro = '',
    int episodeCount = 0,
    String colorDominate = '',
  }) async {
    if (sourceId.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.read(txn, type, sourceId);
      if (existing != null && existing.onShelf) return;
      final base = existing ?? LibraryRecord(type: type, sourceId: sourceId);
      await LibraryDb.write(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? title : base.title,
          author: base.author.isEmpty ? author : base.author,
          cover: base.cover.isEmpty ? cover : base.cover,
          intro: base.intro.isEmpty ? intro : base.intro,
          episodeCount: base.episodeCount == 0
              ? episodeCount
              : base.episodeCount,
          colorDominate: base.colorDominate.isEmpty
              ? colorDominate
              : base.colorDominate,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          shelfAt: now,
          shelfRemovedAt: 0,
        ),
      );
      written = true;
    });
    if (!written) return;
    _bumpShelf(type);
  }

  Future<void> _removeFromShelf(LibraryType type, String sourceId) async {
    if (sourceId.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.read(txn, type, sourceId);
      if (existing == null || !existing.onShelf) return;
      await LibraryDb.write(txn, existing.copyWith(shelfRemovedAt: now));
      written = true;
    });
    if (!written) return;
    _bumpShelf(type);
  }

  Future<void> _saveProgress(
    LibraryType type,
    String sourceId, {
    required String title,
    String cover = '',
    String progressRef = '',
    required int progressIndex,
    int progressSub = 0,
  }) async {
    if (sourceId.isEmpty) return;
    if (type == LibraryType.novel && progressRef.isEmpty) return;
    final db = await _db;
    final now = _now();
    await db.transaction((txn) async {
      final existing = await LibraryDb.read(txn, type, sourceId);
      final base = existing ?? LibraryRecord(type: type, sourceId: sourceId);
      await LibraryDb.write(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? title : base.title,
          cover: base.cover.isEmpty ? cover : base.cover,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          lastReadAt: now,
          progressRef: progressRef,
          progressIndex: progressIndex,
          progressSub: progressSub,
        ),
      );
      // 新增一行（第一次读这本书）不受节流：上限要立刻生效。同一本书的反复
      // 翻页只是 UPDATE，不必每次都数一遍表，按 [pruneInterval] 收敛即可。
      if (existing == null ||
          now - _lastPruneAt >= pruneInterval.inMilliseconds) {
        _lastPruneAt = now;
        await LibraryDb.prune(txn, libraryLimit);
      }
    });
    if (type == LibraryType.novel) {
      recentRevision.value++;
      novelRevision.value++;
    } else {
      videoHistoryRevision.value++;
      videoRevision.value++;
    }
  }

  void _bumpShelf(LibraryType type) {
    if (type == LibraryType.novel) {
      shelfRevision.value++;
      novelRevision.value++;
    } else {
      videoShelfRevision.value++;
      videoRevision.value++;
    }
  }

  // ---------------------------------------------------------------------
  // 云同步：导出 / 合并
  // ---------------------------------------------------------------------

  /// 导出同步数据：`{'items': [记录...]}`，按主键升序保证序列化结果稳定。
  Future<Map<String, dynamic>> exportSyncData() async {
    final records = await LibraryDb.readAll(await _db);
    return {
      'items': [for (final record in records) record.toJson()],
    };
  }

  /// 把远端快照合并进本地，返回是否有变化。
  ///
  /// 合并规则见 [mergeLibraryRecords]；整段在一个事务里，不会留下半合并状态。
  /// 只认当前格式（`items` 数组），旧格式由同步层直接拒绝，避免静默清空远端。
  Future<bool> applySyncData(Map<String, dynamic> remote) async {
    final db = await _db;
    var changed = false;
    var shelfChanged = false;
    var historyChanged = false;
    var videoShelfChanged = false;
    var videoHistoryChanged = false;

    final incoming = <LibraryRecord>[];
    for (final raw in asList(remote['items'])) {
      final record = LibraryRecord.tryFromJson(raw);
      if (record != null) incoming.add(record);
    }

    await db.transaction((txn) async {
      for (final remoteRecord in incoming) {
        final local =
            await LibraryDb.read(txn, remoteRecord.type, remoteRecord.sourceId) ??
            LibraryRecord(
              type: remoteRecord.type,
              sourceId: remoteRecord.sourceId,
            );
        final merged = mergeLibraryRecords(local, remoteRecord);
        if (!merged.diffFrom(local)) continue;
        if (merged.shelfDiffersFrom(local)) {
          if (merged.type == LibraryType.novel) {
            shelfChanged = true;
          } else {
            videoShelfChanged = true;
          }
        }
        if (merged.progressDiffersFrom(local)) {
          if (merged.type == LibraryType.novel) {
            historyChanged = true;
          } else {
            videoHistoryChanged = true;
          }
        }
        await LibraryDb.write(txn, merged);
        changed = true;
      }
      await LibraryDb.prune(txn, libraryLimit);
    });

    if (changed) {
      novelRevision.value++;
      videoRevision.value++;
      if (shelfChanged) shelfRevision.value++;
      if (historyChanged) recentRevision.value++;
      if (videoShelfChanged) videoShelfRevision.value++;
      if (videoHistoryChanged) videoHistoryRevision.value++;
    }
    return changed;
  }
}
