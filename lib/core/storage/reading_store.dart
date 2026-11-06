import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

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

/// 书架与阅读进度的本地存储。
///
/// 只用 shared_preferences 存"小而重要"的状态；正文不落盘（离线缓存是后续
/// 功能，届时加一层明文/密文存储实现即可，接口不变）。
class ReadingStore {
  /// 小说侧（书架 / 阅读进度）变更计数。跨页面的 UI（如"我的"）监听它来刷新，
  /// 避免引入全局状态管理依赖。
  ///
  /// 刻意按小说 / 短剧拆成两个计数：看短剧时每次存进度只 bump
  /// [videoRevision]，否则"我的"页的小说书架、搜索页的收藏态等只关心小说的
  /// UI 会被无关写入带着重读一遍本地数据。
  final ValueNotifier<int> novelRevision = ValueNotifier<int>(0);

  /// 短剧侧（收藏 / 观看进度）变更计数；拆开的原因见 [novelRevision]。
  final ValueNotifier<int> videoRevision = ValueNotifier<int>(0);

  static const _shelfKey = 'shelf_books_v1';
  static const _progressKey = 'reading_progress_v1';

  /// 阅读进度表的 LRU 上限：只保留最近更新过的 [progressLimit] 本。
  ///
  /// 进度表每次保存都全量 `jsonDecode` → 改一条 → `jsonEncode` 写回，长尾
  /// 用户读了几百本后每次翻页都在主 isolate 重写几百 KB（P1-7）。这是文档
  /// 允许的最小方案：表结构不变，只给长度封顶，不进 per-book key 分片 /
  /// sqflite（那需要跨版本迁移，风险大于收益）。被淘汰的是最久没读的书，
  /// 最近阅读入口由独立的 [_recentKey] 维护，不受影响。
  static const int progressLimit = 200;

  /// 短剧收藏（对应小说书架）。
  static const _videoShelfKey = 'video_shelf_v1';

  /// 短剧每部剧看到第几集（对应小说进度表）。
  static const _videoProgressKey = 'video_progress_v1';

  /// 短剧最近观看（对应最近阅读，只留 [videoHistoryLimit] 条）。
  static const _videoHistoryKey = 'video_history_v1';

  /// 最近阅读：独立列表，只保留 [recentLimit] 本。
  ///
  /// 和 [_progressKey] 分开存是刻意的：进度表是"每本书读到哪"（第几本都要能
  /// 继续阅读），最近阅读只是首页展示用的 3 条入口，砍掉旧条目不能影响
  /// 那些书本身的续读位置。
  static const _recentKey = 'recent_reading_v1';

  /// 最近阅读的存储/展示条数。
  static const int recentLimit = 3;

  /// 短剧最近观看的存储/展示条数（与小说最近阅读一致，最多 3 条）。
  static const int videoHistoryLimit = 3;
  static const _lastReadKey = 'last_read_book_v1';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<List<NovelItem>> shelf() async {
    final prefs = await _prefs;
    return _decodeShelf(prefs.getString(_shelfKey));
  }

  Future<bool> isOnShelf(String bookId) async {
    final books = await shelf();
    return books.any((book) => book.id == bookId);
  }

  /// 加入书架；已在架上则不重复写入。
  Future<void> addToShelf(NovelItem item) async {
    if (item.id.isEmpty) return;
    final books = await shelf();
    if (books.any((book) => book.id == item.id)) return;
    books.insert(0, item);
    await _writeShelf(books);
    novelRevision.value++;
  }

  Future<void> removeFromShelf(String bookId) async {
    final books = await shelf();
    books.removeWhere((book) => book.id == bookId);
    await _writeShelf(books);
    novelRevision.value++;
  }

  // ---------------------------------------------------------------------
  // 短剧：收藏 / 观看进度 / 最近观看
  // ---------------------------------------------------------------------

  Future<List<VideoSeries>> videoShelf() async {
    final prefs = await _prefs;
    return _decodeVideoShelf(prefs.getString(_videoShelfKey));
  }

  Future<bool> isVideoOnShelf(String seriesId) async {
    final books = await videoShelf();
    return books.any((item) => item.id == seriesId);
  }

  /// 加入收藏；已收藏则不重复写入。
  Future<void> addVideoToShelf(VideoSeries item) async {
    if (item.id.isEmpty) return;
    final items = await videoShelf();
    if (items.any((entry) => entry.id == item.id)) return;
    items.insert(0, item);
    await _writeVideoShelf(items);
    videoRevision.value++;
  }

  Future<void> removeVideoFromShelf(String seriesId) async {
    final items = await videoShelf();
    items.removeWhere((item) => item.id == seriesId);
    await _writeVideoShelf(items);
    videoRevision.value++;
  }

  /// 记一次观看进度；顺带刷新最近观看（最多 [videoHistoryLimit] 条）。
  Future<void> saveVideoProgress({
    required String seriesId,
    required String title,
    String cover = '',
    required int episodeIndex,
  }) async {
    if (seriesId.isEmpty) return;
    final prefs = await _prefs;
    final entry = VideoWatchProgress(
      seriesId: seriesId,
      title: title,
      cover: cover,
      episodeIndex: episodeIndex,
      updatedAt: DateTime.now(),
    );
    final map = _decodeVideoProgress(prefs.getString(_videoProgressKey))
      ..[seriesId] = entry.toJson();
    await prefs.setString(_videoProgressKey, jsonEncode(map));

    final history = _decodeVideoHistory(prefs.getString(_videoHistoryKey))
      ..removeWhere((item) => asString(item['seriesId']) == seriesId)
      ..insert(0, entry.toJson());
    if (history.length > videoHistoryLimit) {
      history.removeRange(videoHistoryLimit, history.length);
    }
    await prefs.setString(_videoHistoryKey, jsonEncode(history));
    videoRevision.value++;
  }

  Future<VideoWatchProgress?> videoProgress(String seriesId) async {
    final prefs = await _prefs;
    final raw = _decodeVideoProgress(
      prefs.getString(_videoProgressKey),
    )[seriesId];
    return raw == null ? null : VideoWatchProgress.fromJson(raw);
  }

  /// 最近观看（按观看时间倒序，最多 [videoHistoryLimit] 条）。
  Future<List<VideoWatchProgress>> videoHistory({
    int limit = videoHistoryLimit,
  }) async {
    final prefs = await _prefs;
    var entries = _decodeVideoHistory(prefs.getString(_videoHistoryKey));
    if (entries.isEmpty) {
      // 老版本可能只有进度表：按更新时间补出最近几条。
      final progress = _decodeVideoProgress(prefs.getString(_videoProgressKey));
      final derived = progress.values.toList()
        ..sort(
          (a, b) => asInt(b['updatedAt']).compareTo(asInt(a['updatedAt'])),
        );
      entries = derived.take(limit).toList();
      if (entries.isNotEmpty) {
        await prefs.setString(_videoHistoryKey, jsonEncode(entries));
      }
    }
    return entries
        .map(VideoWatchProgress.fromJson)
        .whereType<VideoWatchProgress>()
        .take(limit)
        .toList();
  }

  Future<void> saveProgress({
    required String bookId,
    required String bookTitle,
    required String cover,
    required String chapterId,
    required int chapterIndex,
    int blockIndex = 0,
  }) async {
    if (bookId.isEmpty || chapterId.isEmpty) return;
    final prefs = await _prefs;
    final map = _decodeProgress(prefs.getString(_progressKey))
      ..[bookId] = ReadingProgress(
        bookId: bookId,
        bookTitle: bookTitle,
        cover: cover,
        chapterId: chapterId,
        chapterIndex: chapterIndex,
        blockIndex: blockIndex,
        updatedAt: DateTime.now(),
      ).toJson();
    _pruneProgress(map);
    await prefs.setString(_progressKey, jsonEncode(map));

    // 最近阅读单独一张表，只留最近 [recentLimit] 本。
    final recent = _decodeRecent(prefs.getString(_recentKey))
      ..removeWhere((entry) => asString(entry['bookId']) == bookId)
      ..insert(0, map[bookId]!);
    if (recent.length > recentLimit) {
      recent.removeRange(recentLimit, recent.length);
    }
    await prefs.setString(_recentKey, jsonEncode(recent));

    await prefs.setString(_lastReadKey, bookId);
    novelRevision.value++;
  }

  /// 按 `updatedAt` 淘汰最旧的条目，把进度表收敛到 [progressLimit] 本。
  ///
  /// 只处理"本次写入后超限"的情况；同一毫秒写入的并列条目淘汰顺序不保证，
  /// 但它们都同样"旧"，对续读位置没有影响。
  void _pruneProgress(Map<String, Map<String, dynamic>> progress) {
    if (progress.length <= progressLimit) return;
    final excess = progress.length - progressLimit;
    final byAge = progress.keys.toList()
      ..sort(
        (a, b) =>
            asInt(progress[a]!['updatedAt'])
                .compareTo(asInt(progress[b]!['updatedAt'])),
      );
    for (final bookId in byAge.take(excess)) {
      progress.remove(bookId);
    }
  }

  Future<ReadingProgress?> progress(String bookId) async {
    final prefs = await _prefs;
    final raw = _decodeProgress(prefs.getString(_progressKey))[bookId];
    return raw == null ? null : ReadingProgress.fromJson(raw);
  }

  Future<String?> lastReadBookId() async {
    final prefs = await _prefs;
    return prefs.getString(_lastReadKey);
  }

  /// 最近阅读（按最近一次阅读时间倒序，最多 [recentLimit] 条）。
  Future<List<ReadingProgress>> recent({int limit = recentLimit}) async {
    final prefs = await _prefs;
    var entries = _decodeRecent(prefs.getString(_recentKey));
    if (entries.isEmpty) {
      // 老版本只有进度表：首次读取时按更新时间补出最近几条并落盘，避免升级后
      // "最近阅读" 空白直到用户再读一本。
      final progress = _decodeProgress(prefs.getString(_progressKey));
      final derived = progress.values.toList()
        ..sort(
          (a, b) => asInt(b['updatedAt']).compareTo(asInt(a['updatedAt'])),
        );
      entries = derived.take(limit).toList();
      if (entries.isNotEmpty) {
        await prefs.setString(_recentKey, jsonEncode(entries));
      }
    }
    return entries
        .map(ReadingProgress.fromJson)
        .whereType<ReadingProgress>()
        .take(limit)
        .toList();
  }

  List<VideoSeries> _decodeVideoShelf(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .map(asMap)
          .whereType<Map<String, dynamic>>()
          .map(VideoSeries.fromStorageJson)
          .where((item) => item.isValid)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeVideoShelf(List<VideoSeries> items) async {
    final prefs = await _prefs;
    await prefs.setString(
      _videoShelfKey,
      jsonEncode(items.map((item) => item.toStorageJson()).toList()),
    );
  }

  List<Map<String, dynamic>> _decodeVideoHistory(String? raw) =>
      _decodeMapList(raw);

  Map<String, Map<String, dynamic>> _decodeVideoProgress(String? raw) =>
      _decodeKeyedMap(raw);

  List<Map<String, dynamic>> _decodeRecent(String? raw) => _decodeMapList(raw);

  List<Map<String, dynamic>> _decodeMapList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list.map(asMap).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  List<NovelItem> _decodeShelf(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .map(asMap)
          .whereType<Map<String, dynamic>>()
          .map(NovelItem.fromStorageJson)
          .where((item) => item.isValid)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, Map<String, dynamic>> _decodeProgress(String? raw) =>
      _decodeKeyedMap(raw);

  Map<String, Map<String, dynamic>> _decodeKeyedMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      final map = asMap(decoded);
      if (map == null) return {};
      return {
        for (final entry in map.entries)
          if (asMap(entry.value) != null) entry.key: asMap(entry.value)!,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeShelf(List<NovelItem> books) async {
    final prefs = await _prefs;
    await prefs.setString(
      _shelfKey,
      jsonEncode(books.map((book) => book.toStorageJson()).toList()),
    );
  }
}
