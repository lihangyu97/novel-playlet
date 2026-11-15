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
  /// 小说侧（书架 / 阅读进度）的**聚合**变更计数。跨页面的 UI（如"我的"）
  /// 监听它来刷新，避免引入全局状态管理依赖。
  ///
  /// 早期所有小说写入都只 bump 这一个计数，于是「我的」页的书架和最近阅读
  /// 被绑在一起：阅读页每 400ms 落一次进度，保活的「我的」页就要把书架
  /// （shared_preferences 全量解码）与整页重建一次（CODE_REVIEW P1-5）。
  ///
  /// 现在写入会同时 bump 更细的 [shelfRevision] / [recentRevision]：只关心
  /// 其中一块的 UI 订阅细分通道，需要"小说侧任意写入都刷新"的消费者才用这个
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

  static const _shelfKey = 'shelf_books_v1';
  static const _progressKey = 'reading_progress_v1';

  /// 书架条目的同步元数据：id -> {u: 最后修改毫秒, d: 是否已删除}。
  ///
  /// 书架列表本身没有时间戳，无法在多设备之间判断「这台设备删除」和
  /// 「另一台设备仍保留」谁更新；单独记 tombstone 才能让删除也同步。
  static const _novelShelfMetaKey = 'novel_shelf_meta_v1';

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
  static const _videoShelfMetaKey = 'video_shelf_meta_v1';

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
    await _touchShelfMeta(_novelShelfMetaKey, item.id, deleted: false);
    shelfRevision.value++;
    novelRevision.value++;
  }

  Future<void> removeFromShelf(String bookId) async {
    final books = await shelf();
    books.removeWhere((book) => book.id == bookId);
    await _writeShelf(books);
    await _touchShelfMeta(_novelShelfMetaKey, bookId, deleted: true);
    shelfRevision.value++;
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
    await _touchShelfMeta(_videoShelfMetaKey, item.id, deleted: false);
    videoShelfRevision.value++;
    videoRevision.value++;
  }

  Future<void> removeVideoFromShelf(String seriesId) async {
    final items = await videoShelf();
    items.removeWhere((item) => item.id == seriesId);
    await _writeVideoShelf(items);
    await _touchShelfMeta(_videoShelfMetaKey, seriesId, deleted: true);
    videoShelfRevision.value++;
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
    videoHistoryRevision.value++;
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
    recentRevision.value++;
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

  // ---------------------------------------------------------------------
  // 云同步：导出 / 合并
  // ---------------------------------------------------------------------

  /// 导出同步所需的全部本地数据。
  ///
  /// 最近阅读/最近观看不单独导出：它们可以从进度表按 `updatedAt` 重建，
  /// 少一份可能冲突的数据。书架条目带独立同步元数据，删除也能同步出去。
  Future<Map<String, dynamic>> exportSyncData() async {
    final prefs = await _prefs;
    final novelShelf = _decodeShelf(prefs.getString(_shelfKey));
    final videoShelf = _decodeVideoShelf(prefs.getString(_videoShelfKey));
    final novelMeta = await _ensureShelfMeta(
      _novelShelfMetaKey,
      novelShelf.map((item) => item.id),
    );
    final videoMeta = await _ensureShelfMeta(
      _videoShelfMetaKey,
      videoShelf.map((item) => item.id),
    );
    return {
      'novelShelf': [for (final item in novelShelf) item.toStorageJson()],
      'novelShelfMeta': novelMeta,
      'novelProgress': _decodeProgress(prefs.getString(_progressKey)),
      'videoShelf': [for (final item in videoShelf) item.toStorageJson()],
      'videoShelfMeta': videoMeta,
      'videoProgress': _decodeVideoProgress(prefs.getString(_videoProgressKey)),
    };
  }

  /// 把远端快照合并进本地，返回是否有变化。
  ///
  /// - 书架/收藏按条目 tombstone 做最后写入优先，删除也会同步；
  /// - 进度按 `updatedAt` 取较新的一条；
  /// - 最近阅读/最近观看由合并后的进度重建，避免三份列表互相打架。
  Future<bool> applySyncData(Map<String, dynamic> remote) async {
    final prefs = await _prefs;
    var novelChanged = false;
    var novelShelfChanged = false;
    var novelRecentChanged = false;
    var videoChanged = false;
    var videoShelfChanged = false;
    var videoRecentChanged = false;

    // 小说书架 + 元数据
    final localShelf = _decodeShelf(prefs.getString(_shelfKey));
    final remoteShelf = _decodeShelf(jsonEncode(remote['novelShelf'] ?? []));
    final localMeta = await _ensureShelfMeta(
      _novelShelfMetaKey,
      localShelf.map((item) => item.id),
    );
    final remoteMeta = _decodeShelfMeta(remote['novelShelfMeta']);
    // 兼容没有元数据的旧快照：列表里存在的条目按“未删除、时间 0”参与合并。
    for (final item in remoteShelf) {
      remoteMeta.putIfAbsent(item.id, () => {'u': 0, 'd': false});
    }
    final mergedMeta = _mergeShelfMeta(localMeta, remoteMeta);
    final localItems = {for (final item in localShelf) item.id: item};
    final remoteItems = {for (final item in remoteShelf) item.id: item};
    final mergedShelf = <NovelItem>[];
    final orderedIds = mergedMeta.keys.toList()
      ..sort(
        (a, b) =>
            asInt(mergedMeta[b]!['u']).compareTo(asInt(mergedMeta[a]!['u'])),
      );
    for (final id in orderedIds) {
      if (mergedMeta[id]!['d'] == true) continue;
      final item = localItems[id] ?? remoteItems[id];
      if (item != null) mergedShelf.add(item);
    }
    final shelfJson = jsonEncode([
      for (final item in mergedShelf) item.toStorageJson(),
    ]);
    if (prefs.getString(_shelfKey) != shelfJson) {
      await prefs.setString(_shelfKey, shelfJson);
      novelChanged = true;
      novelShelfChanged = true;
    }
    final metaJson = jsonEncode(mergedMeta);
    if (prefs.getString(_novelShelfMetaKey) != metaJson) {
      await prefs.setString(_novelShelfMetaKey, metaJson);
      novelChanged = true;
    }

    // 小说进度
    final localProgress = _decodeProgress(prefs.getString(_progressKey));
    final remoteProgress = _decodeKeyedMap(
      jsonEncode(remote['novelProgress'] ?? {}),
    );
    final mergedProgress = _mergeProgress(localProgress, remoteProgress);
    _pruneProgress(mergedProgress);
    final progressJson = jsonEncode(mergedProgress);
    if (prefs.getString(_progressKey) != progressJson) {
      await prefs.setString(_progressKey, progressJson);
      novelChanged = true;
      novelRecentChanged = true;
    }
    final recentJson = jsonEncode(
      _recentFromProgress(mergedProgress, recentLimit),
    );
    if (prefs.getString(_recentKey) != recentJson) {
      await prefs.setString(_recentKey, recentJson);
      novelChanged = true;
      novelRecentChanged = true;
    }
    final lastRead = _recentFromProgress(mergedProgress, 1);
    final lastReadId = lastRead.isEmpty
        ? null
        : asString(lastRead.first['bookId']);
    if (lastReadId != null && lastReadId.isNotEmpty) {
      if (prefs.getString(_lastReadKey) != lastReadId) {
        await prefs.setString(_lastReadKey, lastReadId);
        novelChanged = true;
      }
    }

    // 短剧收藏 + 元数据
    final localVideoShelf = _decodeVideoShelf(prefs.getString(_videoShelfKey));
    final remoteVideoShelf = _decodeVideoShelf(
      jsonEncode(remote['videoShelf'] ?? []),
    );
    final localVideoMeta = await _ensureShelfMeta(
      _videoShelfMetaKey,
      localVideoShelf.map((item) => item.id),
    );
    final remoteVideoMeta = _decodeShelfMeta(remote['videoShelfMeta']);
    final mergedVideoMeta = _mergeShelfMeta(localVideoMeta, remoteVideoMeta);
    final localVideoItems = {for (final item in localVideoShelf) item.id: item};
    final remoteVideoItems = {
      for (final item in remoteVideoShelf) item.id: item,
    };
    final mergedVideoShelf = <VideoSeries>[];
    final orderedVideoIds = mergedVideoMeta.keys.toList()
      ..sort(
        (a, b) =>
            asInt(mergedVideoMeta[b]!['u'])
                .compareTo(asInt(mergedVideoMeta[a]!['u'])),
      );
    for (final id in orderedVideoIds) {
      if (mergedVideoMeta[id]!['d'] == true) continue;
      final item = localVideoItems[id] ?? remoteVideoItems[id];
      if (item != null) mergedVideoShelf.add(item);
    }
    final videoShelfJson = jsonEncode([
      for (final item in mergedVideoShelf) item.toStorageJson(),
    ]);
    if (prefs.getString(_videoShelfKey) != videoShelfJson) {
      await prefs.setString(_videoShelfKey, videoShelfJson);
      videoChanged = true;
      videoShelfChanged = true;
    }
    final videoMetaJson = jsonEncode(mergedVideoMeta);
    if (prefs.getString(_videoShelfMetaKey) != videoMetaJson) {
      await prefs.setString(_videoShelfMetaKey, videoMetaJson);
      videoChanged = true;
    }

    // 短剧进度 + 最近观看
    final localVideoProgress = _decodeVideoProgress(
      prefs.getString(_videoProgressKey),
    );
    final remoteVideoProgress = _decodeKeyedMap(
      jsonEncode(remote['videoProgress'] ?? {}),
    );
    final mergedVideoProgress = _mergeProgress(
      localVideoProgress,
      remoteVideoProgress,
    );
    final videoProgressJson = jsonEncode(mergedVideoProgress);
    if (prefs.getString(_videoProgressKey) != videoProgressJson) {
      await prefs.setString(_videoProgressKey, videoProgressJson);
      videoChanged = true;
      videoRecentChanged = true;
    }
    final videoHistoryJson = jsonEncode(
      _recentFromProgress(mergedVideoProgress, videoHistoryLimit),
    );
    if (prefs.getString(_videoHistoryKey) != videoHistoryJson) {
      await prefs.setString(_videoHistoryKey, videoHistoryJson);
      videoChanged = true;
      videoRecentChanged = true;
    }

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

  Future<Map<String, Map<String, dynamic>>> _ensureShelfMeta(
    String key,
    Iterable<String> activeIds,
  ) async {
    final prefs = await _prefs;
    final meta = _decodeShelfMeta(prefs.getString(key));
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in activeIds) {
      final current = meta[id];
      if (current == null) {
        meta[id] = {'u': 0, 'd': false};
        changed = true;
      } else if (current['d'] == true) {
        // 列表里还有这条，却被标成删除：以列表为准恢复；用当前时间避免
        // 远端旧 tombstone 再把刚恢复的收藏删掉。
        meta[id] = {'u': now, 'd': false};
        changed = true;
      }
    }
    if (changed) await prefs.setString(key, jsonEncode(meta));
    return meta;
  }

  Future<void> _touchShelfMeta(
    String key,
    String id, {
    required bool deleted,
  }) async {
    final prefs = await _prefs;
    final meta = _decodeShelfMeta(prefs.getString(key));
    meta[id] = {'u': DateTime.now().millisecondsSinceEpoch, 'd': deleted};
    await prefs.setString(key, jsonEncode(meta));
  }

  Map<String, Map<String, dynamic>> _decodeShelfMeta(Object? raw) {
    Map<String, dynamic>? map;
    if (raw is String) {
      try {
        map = asMap(jsonDecode(raw));
      } catch (_) {
        map = null;
      }
    } else {
      map = asMap(raw);
    }
    if (map == null) return {};
    final out = <String, Map<String, dynamic>>{};
    for (final entry in map.entries) {
      final value = asMap(entry.value);
      if (value == null) continue;
      out[entry.key] = {'u': asInt(value['u']), 'd': value['d'] == true};
    }
    return out;
  }

  Map<String, Map<String, dynamic>> _mergeShelfMeta(
    Map<String, Map<String, dynamic>> local,
    Map<String, Map<String, dynamic>> remote,
  ) {
    final out = <String, Map<String, dynamic>>{};
    for (final source in [local, remote]) {
      for (final entry in source.entries) {
        final existing = out[entry.key];
        if (existing == null ||
            asInt(entry.value['u']) > asInt(existing['u']) ||
            (asInt(entry.value['u']) == asInt(existing['u']) &&
                entry.value['d'] == true &&
                existing['d'] != true)) {
          out[entry.key] = entry.value;
        }
      }
    }
    return out;
  }

  Map<String, Map<String, dynamic>> _mergeProgress(
    Map<String, Map<String, dynamic>> local,
    Map<String, Map<String, dynamic>> remote,
  ) {
    final out = <String, Map<String, dynamic>>{...local};
    for (final entry in remote.entries) {
      final existing = out[entry.key];
      if (existing == null ||
          asInt(entry.value['updatedAt']) > asInt(existing['updatedAt'])) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _recentFromProgress(
    Map<String, Map<String, dynamic>> progress,
    int limit,
  ) {
    final entries = progress.values.toList()
      ..sort((a, b) => asInt(b['updatedAt']).compareTo(asInt(a['updatedAt'])));
    return entries.take(limit).toList();
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
