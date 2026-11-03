import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';

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
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        asInt(json['updatedAt']),
      ),
    );
  }
}

/// 书架与阅读进度的本地存储。
///
/// 只用 shared_preferences 存"小而重要"的状态；正文不落盘（离线缓存是后续
/// 功能，届时加一层明文/密文存储实现即可，接口不变）。
class ReadingStore {
  /// 书架/进度变更计数。跨页面的 UI（如"我的"）监听它来刷新，避免引入
  /// 全局状态管理依赖。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const _shelfKey = 'shelf_books_v1';
  static const _progressKey = 'reading_progress_v1';

  /// 最近阅读：独立列表，只保留 [recentLimit] 本。
  ///
  /// 和 [_progressKey] 分开存是刻意的：进度表是"每本书读到哪"（第几本都要能
  /// 继续阅读），最近阅读只是首页展示用的 3 条入口，砍掉旧条目不能影响
  /// 那些书本身的续读位置。
  static const _recentKey = 'recent_reading_v1';

  /// 最近阅读的存储/展示条数。
  static const int recentLimit = 3;
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
    revision.value++;
  }

  Future<void> removeFromShelf(String bookId) async {
    final books = await shelf();
    books.removeWhere((book) => book.id == bookId);
    await _writeShelf(books);
    revision.value++;
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
    revision.value++;
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
      final derived =
          progress.values.toList()
            ..sort(
              (a, b) =>
                  asInt(b['updatedAt']).compareTo(asInt(a['updatedAt'])),
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

  List<Map<String, dynamic>> _decodeRecent(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .map(asMap)
          .whereType<Map<String, dynamic>>()
          .toList();
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

  Map<String, Map<String, dynamic>> _decodeProgress(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      final map = asMap(decoded);
      if (map == null) return {};
      return {
        for (final entry in map.entries)
          if (asMap(entry.value) != null)
            entry.key: asMap(entry.value)!,
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
