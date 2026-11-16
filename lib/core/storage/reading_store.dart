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

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'bookTitle': bookTitle,
    'cover': cover,
    'chapterId': chapterId,
    'chapterIndex': chapterIndex,
    'blockIndex': blockIndex,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static ReadingProgress? fromJson(Map<String, dynamic> json) {
    final bookId = asString(json['bookId']);
    if (bookId.isEmpty) return null;
    return ReadingProgress(
      bookId: bookId,
      bookTitle: asString(json['bookTitle']),
      cover: asString(json['cover']),
      chapterId: asString(json['chapterId']),
      chapterIndex: asInt(json['chapterIndex']),
      blockIndex: asInt(json['blockIndex']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(asInt(json['updatedAt'])),
    );
  }
}

/// 一部短剧的观看进度。
///
/// 与小说 [ReadingProgress] 对齐：只记「看到第几集 + 时间」，点进去直接续播。
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

  Map<String, dynamic> toJson() => {
    'seriesId': seriesId,
    'title': title,
    'cover': cover,
    'episodeIndex': episodeIndex,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static VideoWatchProgress? fromJson(Map<String, dynamic> json) {
    final seriesId = asString(json['seriesId']);
    if (seriesId.isEmpty) return null;
    return VideoWatchProgress(
      seriesId: seriesId,
      title: asString(json['title']),
      cover: asString(json['cover']),
      episodeIndex: asInt(json['episodeIndex']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(asInt(json['updatedAt'])),
    );
  }
}

/// 书架 / 收藏 / 进度的门面（SQLite 实现）。
///
/// 数据模型见 `docs/storage-model-proposal.md`：每条内容一条记录，按生命周期
/// 拆「用户状态 / 上游快照」两张表；书架、最近阅读、最近观看全部由这两张表
/// 派生，不再单独存列表，因此不存在"最近列表和进度表不一致"的问题。
///
/// 页面只通过这里的 revision 计数感知变更，不要自己去读库。
class ReadingStore {
  /// 小说侧（书架 / 阅读进度）的**聚合**变更计数。跨页面的 UI（如"我的"）
  /// 监听它来刷新，避免引入全局状态管理依赖。
  ///
  /// 写入会同时 bump 更细的 [shelfRevision] / [recentRevision]：只关心其中
  /// 一块的 UI 订阅细分通道，需要"小说侧任意写入都刷新"的消费者才用这个
  /// 聚合计数。短剧侧同理见 [videoShelfRevision] / [videoHistoryRevision]。
  final ValueNotifier<int> novelRevision = ValueNotifier<int>(0);

  /// 小说侧「书架内容」变更计数：加入 / 移出书架。阅读进度写入不动它。
  final ValueNotifier<int> shelfRevision = ValueNotifier<int>(0);

  /// 小说侧「最近阅读」变更计数：保存阅读进度（含书架内外的书）。书架内容
  /// 写入不动它。
  final ValueNotifier<int> recentRevision = ValueNotifier<int>(0);

  /// 短剧侧（收藏 / 观看进度）的聚合变更计数；拆分原因见 [novelRevision]。
  final ValueNotifier<int> videoRevision = ValueNotifier<int>(0);

  /// 短剧侧「收藏」变更计数：加入 / 移出收藏。
  final ValueNotifier<int> videoShelfRevision = ValueNotifier<int>(0);

  /// 短剧侧「最近观看」变更计数：保存观看进度。
  final ValueNotifier<int> videoHistoryRevision = ValueNotifier<int>(0);

  /// 最近阅读 / 最近观看的展示与落盘条数。
  static const int recentLimit = 3;
  static const int videoHistoryLimit = 3;

  /// 每条内容链最多保留的**纯进度行**数量（读过但没上过架的书 / 剧）。
  ///
  /// 书架条目与墓碑不计入、也不淘汰：墓碑是删除能同步出去的唯一依据，删早了
  /// 远端旧值会把条目复活。小说侧原来在进度表上封顶 200，短剧侧没有上限，
  /// 这里统一收敛。
  static const int libraryLimit = 500;

  Future<Database> get _db => LibraryDb.instance();

  /// 进程内单调递增的毫秒时间戳。
  ///
  /// LWW 全靠它排序，而 `DateTime.now()` 在同一毫秒内的连续调用会相等——
  /// 快速连点选集/连续翻页时会让"最近观看"顺序和后写覆盖前写都失准。
  /// 这里保证严格递增。
  int _stamp = 0;

  int _now() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _stamp = now > _stamp ? now : _stamp + 1;
    return _stamp;
  }

  // ---------------------------------------------------------------------
  // 小说：书架
  // ---------------------------------------------------------------------

  Future<List<NovelItem>> shelf() async {
    final records = await LibraryDb.readNovelShelf(await _db);
    return [
      for (final record in records)
        NovelItem(
          id: record.id,
          title: record.title,
          cover: record.cover,
          author: record.author,
          colorDominate: record.colorDominate,
        ),
    ];
  }

  Future<bool> isOnShelf(String bookId) async {
    if (bookId.isEmpty) return false;
    final record = await LibraryDb.readNovel(await _db, bookId);
    return record?.onShelf ?? false;
  }

  /// 加入书架；已在架上则不重复写入。
  Future<void> addToShelf(NovelItem item) async {
    if (item.id.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.readNovel(txn, item.id);
      if (existing != null && existing.onShelf) return;
      final base = existing ?? NovelRecord(id: item.id);
      await LibraryDb.writeNovel(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? item.title : base.title,
          author: base.author.isEmpty ? item.author : base.author,
          cover: base.cover.isEmpty ? item.cover : base.cover,
          colorDominate: base.colorDominate.isEmpty
              ? item.colorDominate
              : base.colorDominate,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          shelfAt: now,
          shelfRemovedAt: 0,
        ),
      );
      written = true;
    });
    if (!written) return;
    shelfRevision.value++;
    novelRevision.value++;
  }

  Future<void> removeFromShelf(String bookId) async {
    if (bookId.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.readNovel(txn, bookId);
      if (existing == null || !existing.onShelf) return;
      await LibraryDb.writeNovel(txn, existing.copyWith(shelfRemovedAt: now));
      written = true;
    });
    if (!written) return;
    shelfRevision.value++;
    novelRevision.value++;
  }

  // ---------------------------------------------------------------------
  // 小说：阅读进度 / 最近阅读
  // ---------------------------------------------------------------------

  Future<void> saveProgress({
    required String bookId,
    required String bookTitle,
    required String cover,
    required String chapterId,
    required int chapterIndex,
    int blockIndex = 0,
  }) async {
    if (bookId.isEmpty || chapterId.isEmpty) return;
    final db = await _db;
    final now = _now();
    await db.transaction((txn) async {
      final existing = await LibraryDb.readNovel(txn, bookId);
      final base = existing ?? NovelRecord(id: bookId);
      await LibraryDb.writeNovel(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? bookTitle : base.title,
          cover: base.cover.isEmpty ? cover : base.cover,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          lastReadAt: now,
          chapterId: chapterId,
          chapterIndex: chapterIndex,
          blockIndex: blockIndex,
        ),
      );
      await LibraryDb.pruneNovel(txn, libraryLimit);
    });
    recentRevision.value++;
    novelRevision.value++;
  }

  Future<ReadingProgress?> progress(String bookId) async {
    if (bookId.isEmpty) return null;
    final record = await LibraryDb.readNovel(await _db, bookId);
    if (record == null || !record.hasProgress) return null;
    return _progressOf(record);
  }

  /// 最近阅读（按最近一次阅读时间倒序，最多 [limit] 条）。
  Future<List<ReadingProgress>> recent({int limit = recentLimit}) async {
    final records = await LibraryDb.readNovelRecent(await _db, limit);
    return [
      for (final record in records)
        if (record.hasProgress) _progressOf(record),
    ];
  }

  ReadingProgress _progressOf(NovelRecord record) => ReadingProgress(
    bookId: record.id,
    bookTitle: record.title,
    cover: record.cover,
    chapterId: record.chapterId,
    chapterIndex: record.chapterIndex,
    blockIndex: record.blockIndex,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(record.lastReadAt),
  );

  // ---------------------------------------------------------------------
  // 短剧：收藏
  // ---------------------------------------------------------------------

  Future<List<VideoSeries>> videoShelf() async {
    final records = await LibraryDb.readVideoShelf(await _db);
    return [
      for (final record in records)
        VideoSeries(
          id: record.id,
          title: record.title,
          cover: record.cover,
          intro: record.intro,
          episodeCount: record.episodeCount,
          colorDominate: record.colorDominate,
        ),
    ];
  }

  Future<bool> isVideoOnShelf(String seriesId) async {
    if (seriesId.isEmpty) return false;
    final record = await LibraryDb.readVideo(await _db, seriesId);
    return record?.onShelf ?? false;
  }

  /// 加入收藏；已收藏则不重复写入。
  Future<void> addVideoToShelf(VideoSeries item) async {
    if (item.id.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.readVideo(txn, item.id);
      if (existing != null && existing.onShelf) return;
      final base = existing ?? VideoRecord(id: item.id);
      await LibraryDb.writeVideo(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? item.title : base.title,
          cover: base.cover.isEmpty ? item.cover : base.cover,
          intro: base.intro.isEmpty ? item.intro : base.intro,
          episodeCount: base.episodeCount == 0
              ? item.episodeCount
              : base.episodeCount,
          colorDominate: base.colorDominate.isEmpty
              ? item.colorDominate
              : base.colorDominate,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          shelfAt: now,
          shelfRemovedAt: 0,
        ),
      );
      written = true;
    });
    if (!written) return;
    videoShelfRevision.value++;
    videoRevision.value++;
  }

  Future<void> removeVideoFromShelf(String seriesId) async {
    if (seriesId.isEmpty) return;
    final db = await _db;
    final now = _now();
    var written = false;
    await db.transaction((txn) async {
      final existing = await LibraryDb.readVideo(txn, seriesId);
      if (existing == null || !existing.onShelf) return;
      await LibraryDb.writeVideo(txn, existing.copyWith(shelfRemovedAt: now));
      written = true;
    });
    if (!written) return;
    videoShelfRevision.value++;
    videoRevision.value++;
  }

  // ---------------------------------------------------------------------
  // 短剧：观看进度 / 最近观看
  // ---------------------------------------------------------------------

  /// 记一次观看进度；最近观看由进度表派生，不再单独维护列表。
  Future<void> saveVideoProgress({
    required String seriesId,
    required String title,
    String cover = '',
    required int episodeIndex,
  }) async {
    if (seriesId.isEmpty) return;
    final db = await _db;
    final now = _now();
    await db.transaction((txn) async {
      final existing = await LibraryDb.readVideo(txn, seriesId);
      final base = existing ?? VideoRecord(id: seriesId);
      await LibraryDb.writeVideo(
        txn,
        base.copyWith(
          title: base.title.isEmpty ? title : base.title,
          cover: base.cover.isEmpty ? cover : base.cover,
          metaFetchedAt: base.metaFetchedAt == 0 ? now : base.metaFetchedAt,
          lastReadAt: now,
          episodeIndex: episodeIndex,
        ),
      );
      await LibraryDb.pruneVideo(txn, libraryLimit);
    });
    videoHistoryRevision.value++;
    videoRevision.value++;
  }

  Future<VideoWatchProgress?> videoProgress(String seriesId) async {
    if (seriesId.isEmpty) return null;
    final record = await LibraryDb.readVideo(await _db, seriesId);
    if (record == null || !record.hasProgress) return null;
    return _videoProgressOf(record);
  }

  /// 最近观看（按观看时间倒序，最多 [limit] 条）。
  Future<List<VideoWatchProgress>> videoHistory({
    int limit = videoHistoryLimit,
  }) async {
    final records = await LibraryDb.readVideoRecent(await _db, limit);
    return [
      for (final record in records)
        if (record.hasProgress) _videoProgressOf(record),
    ];
  }

  VideoWatchProgress _videoProgressOf(VideoRecord record) =>
      VideoWatchProgress(
        seriesId: record.id,
        title: record.title,
        cover: record.cover,
        episodeIndex: record.episodeIndex,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(record.lastReadAt),
      );

  // ---------------------------------------------------------------------
  // 云同步：导出 / 合并
  // ---------------------------------------------------------------------

  /// 导出同步所需的全部本地数据。
  ///
  /// 新格式（schemaVersion 2）：`{'novel': [记录...], 'video': [...]}`，
  /// 一条记录同时带快照与状态。顺序按 id 升序，保证同一份数据每次序列化出的
  /// 字符串完全一致——同步层靠字符串比较决定要不要上传。
  Future<Map<String, dynamic>> exportSyncData() async {
    final db = await _db;
    final novels = await LibraryDb.readAllNovel(db);
    final videos = await LibraryDb.readAllVideo(db);
    return {
      'novel': [for (final record in novels) record.toJson()],
      'video': [for (final record in videos) record.toJson()],
    };
  }

  /// 把远端快照合并进本地，返回是否有变化。
  ///
  /// 合并规则见 [mergeNovelRecords] / [mergeVideoRecords]：快照按
  /// `metaFetchedAt` 整组取新、进度按 `lastReadAt` 整组取新、书架两列各取
  /// max。整段在一个事务里，不会留下半合并状态。
  ///
  /// 兼容 v1 载荷（`novelShelf` / `novelProgress` …）：旧版本写上去的文件
  /// 会先转成记录再合并，避免升级后第一次同步就报"格式不正确"。
  Future<bool> applySyncData(Map<String, dynamic> remote) async {
    final db = await _db;
    var novelChanged = false;
    var novelShelfChanged = false;
    var novelRecentChanged = false;
    var videoChanged = false;
    var videoShelfChanged = false;
    var videoRecentChanged = false;

    final novels = _novelRecordsOf(remote);
    final videos = _videoRecordsOf(remote);

    await db.transaction((txn) async {
      for (final incoming in novels) {
        final local =
            await LibraryDb.readNovel(txn, incoming.id) ??
            NovelRecord(id: incoming.id);
        final merged = mergeNovelRecords(local, incoming);
        if (!merged.diffFrom(local)) continue;
        if (merged.onShelf != local.onShelf) novelShelfChanged = true;
        if (merged.lastReadAt != local.lastReadAt ||
            merged.chapterId != local.chapterId) {
          novelRecentChanged = true;
        }
        await LibraryDb.writeNovel(txn, merged);
        novelChanged = true;
      }
      for (final incoming in videos) {
        final local =
            await LibraryDb.readVideo(txn, incoming.id) ??
            VideoRecord(id: incoming.id);
        final merged = mergeVideoRecords(local, incoming);
        if (!merged.diffFrom(local)) continue;
        if (merged.onShelf != local.onShelf) videoShelfChanged = true;
        if (merged.lastReadAt != local.lastReadAt) videoRecentChanged = true;
        await LibraryDb.writeVideo(txn, merged);
        videoChanged = true;
      }
      await LibraryDb.pruneNovel(txn, libraryLimit);
      await LibraryDb.pruneVideo(txn, libraryLimit);
    });

    if (novelChanged) {
      novelRevision.value++;
      if (novelShelfChanged) shelfRevision.value++;
      if (novelRecentChanged) recentRevision.value++;
    }
    if (videoChanged) {
      videoRevision.value++;
      if (videoShelfChanged) videoShelfRevision.value++;
      if (videoRecentChanged) videoHistoryRevision.value++;
    }
    return novelChanged || videoChanged;
  }

  List<NovelRecord> _novelRecordsOf(Map<String, dynamic> data) {
    if (!isRecordPayload(data)) return novelRecordsFromLegacy(data);
    final out = <NovelRecord>[];
    for (final raw in asList(data['novel'])) {
      final record = NovelRecord.tryFromJson(raw);
      if (record != null) out.add(record);
    }
    return out;
  }

  List<VideoRecord> _videoRecordsOf(Map<String, dynamic> data) {
    if (!isRecordPayload(data)) return videoRecordsFromLegacy(data);
    final out = <VideoRecord>[];
    for (final raw in asList(data['video'])) {
      final record = VideoRecord.tryFromJson(raw);
      if (record != null) out.add(record);
    }
    return out;
  }
}
