import 'dart:async';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/models/json_utils.dart';
import 'library_records.dart';

/// 书架 / 收藏 / 进度的本地库（SQLite）。
///
/// 布局（`docs/storage-model-proposal.md` §3）：每条内容一行，按生命周期拆两张表——
/// - `*_state`：用户状态，翻页/换集就写，行小、写得最频繁；
/// - `*_meta`：上游快照，加入书架时写一次，详情页刷新时再写。
///
/// 拆开之后一次进度落盘只重写状态表，写放大比原来"整张进度表"还低，
/// 同步载荷也不再需要把 title/cover 存两遍。
///
/// 测试通过 [overridePath] 注入 `inMemoryDatabasePath`（见
/// `test/support/library_test_db.dart`），生产路径固定在
/// `<Application Support>/library.db`。
class LibraryDb {
  LibraryDb._();

  static const int schemaVersion = 1;

  static const String novelStateTable = 'novel_state';
  static const String novelMetaTable = 'novel_meta';
  static const String videoStateTable = 'video_state';
  static const String videoMetaTable = 'video_meta';
  static const String kvTable = 'kv';

  static const String _prefsImportedKey = 'prefs_imported_v1';

  /// 测试注入用；为 null 时落到 `<AppSupport>/library.db`。
  static String? overridePath;

  static Database? _db;
  static Future<Database>? _opening;

  /// 进程内单例。并发调用共用一次 open，避免重复建库。
  static Future<Database> instance() async {
    final open = _db;
    if (open != null) return open;
    final pending = _opening;
    if (pending != null) return pending;

    final future = _open();
    _opening = future;
    try {
      final db = await future;
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  /// 关掉当前连接。测试用它重置内存库（`inMemoryDatabasePath` 关掉即销毁）。
  static Future<void> close() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null) {
      await db.close();
    }
  }

  static Future<Database> _open() async {
    final path = overridePath ?? await _defaultPath();
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, _) => _createSchema(db),
    );
    await _migrateFromPreferences(db);
    return db;
  }

  static Future<String> _defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/library.db';
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE $novelStateTable (
        id TEXT PRIMARY KEY,
        last_read_at INTEGER NOT NULL DEFAULT 0,
        chapter_id TEXT NOT NULL DEFAULT '',
        chapter_index INTEGER NOT NULL DEFAULT 0,
        block_index INTEGER NOT NULL DEFAULT 0,
        shelf_at INTEGER NOT NULL DEFAULT 0,
        shelf_removed_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $novelMetaTable (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        color_dominate TEXT NOT NULL DEFAULT '',
        meta_fetched_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $videoStateTable (
        id TEXT PRIMARY KEY,
        last_read_at INTEGER NOT NULL DEFAULT 0,
        episode_index INTEGER NOT NULL DEFAULT 0,
        shelf_at INTEGER NOT NULL DEFAULT 0,
        shelf_removed_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $videoMetaTable (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        intro TEXT NOT NULL DEFAULT '',
        episode_count INTEGER NOT NULL DEFAULT 0,
        color_dominate TEXT NOT NULL DEFAULT '',
        meta_fetched_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $kvTable (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX novel_state_recent ON $novelStateTable(last_read_at DESC)',
    );
    await db.execute(
      'CREATE INDEX novel_state_shelf ON $novelStateTable(shelf_at DESC)',
    );
    await db.execute(
      'CREATE INDEX video_state_recent ON $videoStateTable(last_read_at DESC)',
    );
    await db.execute(
      'CREATE INDEX video_state_shelf ON $videoStateTable(shelf_at DESC)',
    );
  }

  // -------------------------------------------------------------------------
  // 小说
  // -------------------------------------------------------------------------

  static const String _novelSelect = '''
    SELECT s.id AS id, s.last_read_at AS last_read_at,
           s.chapter_id AS chapter_id, s.chapter_index AS chapter_index,
           s.block_index AS block_index, s.shelf_at AS shelf_at,
           s.shelf_removed_at AS shelf_removed_at,
           m.title AS title, m.author AS author, m.cover AS cover,
           m.color_dominate AS color_dominate,
           m.meta_fetched_at AS meta_fetched_at
    FROM $novelStateTable s
    LEFT JOIN $novelMetaTable m ON m.id = s.id
  ''';

  static NovelRecord _novelFromRow(Map<String, Object?> row) => NovelRecord(
    id: asString(row['id']),
    title: asString(row['title']),
    author: asString(row['author']),
    cover: asString(row['cover']),
    colorDominate: asString(row['color_dominate']),
    metaFetchedAt: asInt(row['meta_fetched_at']),
    lastReadAt: asInt(row['last_read_at']),
    chapterId: asString(row['chapter_id']),
    chapterIndex: asInt(row['chapter_index']),
    blockIndex: asInt(row['block_index']),
    shelfAt: asInt(row['shelf_at']),
    shelfRemovedAt: asInt(row['shelf_removed_at']),
  );

  static Future<NovelRecord?> readNovel(
    DatabaseExecutor db,
    String id,
  ) async {
    if (id.isEmpty) return null;
    final rows = await db.rawQuery('$_novelSelect WHERE s.id = ? LIMIT 1', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _novelFromRow(rows.first);
  }

  /// 导出用：按 id 排序，保证同一份数据每次序列化出的字符串完全一致
  /// （同步层靠字符串比较决定要不要上传，顺序不稳会白传）。
  static Future<List<NovelRecord>> readAllNovel(DatabaseExecutor db) async {
    final rows = await db.rawQuery('$_novelSelect ORDER BY s.id ASC');
    return rows.map(_novelFromRow).toList();
  }

  static Future<List<NovelRecord>> readNovelShelf(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery(
      '$_novelSelect '
      'WHERE s.shelf_at > 0 AND s.shelf_at > s.shelf_removed_at '
      'ORDER BY s.shelf_at DESC, s.id ASC',
    );
    return rows.map(_novelFromRow).toList();
  }

  static Future<List<NovelRecord>> readNovelRecent(
    DatabaseExecutor db,
    int limit,
  ) async {
    if (limit <= 0) return const [];
    final rows = await db.rawQuery(
      '$_novelSelect '
      'WHERE s.last_read_at > 0 '
      'ORDER BY s.last_read_at DESC, s.id ASC LIMIT ?',
      [limit],
    );
    return rows.map(_novelFromRow).toList();
  }

  /// 整条记录写回（状态 + 快照）。调用方用 [readNovel] 读-改-写，因此这里
  /// 总是覆盖全部列，不会把没参与的字段清空。
  static Future<void> writeNovel(
    DatabaseExecutor db,
    NovelRecord record,
  ) async {
    await db.insert(novelStateTable, {
      'id': record.id,
      'last_read_at': record.lastReadAt,
      'chapter_id': record.chapterId,
      'chapter_index': record.chapterIndex,
      'block_index': record.blockIndex,
      'shelf_at': record.shelfAt,
      'shelf_removed_at': record.shelfRemovedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(novelMetaTable, {
      'id': record.id,
      'title': record.title,
      'author': record.author,
      'cover': record.cover,
      'color_dominate': record.colorDominate,
      'meta_fetched_at': record.metaFetchedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 收敛记录条数：只淘汰"没上架过、也没有墓碑"的纯进度行，最旧的先走。
  ///
  /// 书架条目与墓碑**永远不删行**：移出书架只是把 [NovelRecord.shelfAt] 留着、
  /// 写一个新的 [NovelRecord.shelfRemovedAt]（墓碑），删行会丢掉"删除"这个事实，
  /// 远端旧值随即把条目复活。所以这个上限只约束"读过但没上架"的行。
  static Future<void> pruneNovel(DatabaseExecutor db, int limit) async {
    await _prune(
      db,
      stateTable: novelStateTable,
      metaTable: novelMetaTable,
      limit: limit,
    );
  }

  // -------------------------------------------------------------------------
  // 短剧
  // -------------------------------------------------------------------------

  static const String _videoSelect = '''
    SELECT s.id AS id, s.last_read_at AS last_read_at,
           s.episode_index AS episode_index, s.shelf_at AS shelf_at,
           s.shelf_removed_at AS shelf_removed_at,
           m.title AS title, m.cover AS cover, m.intro AS intro,
           m.episode_count AS episode_count,
           m.color_dominate AS color_dominate,
           m.meta_fetched_at AS meta_fetched_at
    FROM $videoStateTable s
    LEFT JOIN $videoMetaTable m ON m.id = s.id
  ''';

  static VideoRecord _videoFromRow(Map<String, Object?> row) => VideoRecord(
    id: asString(row['id']),
    title: asString(row['title']),
    cover: asString(row['cover']),
    intro: asString(row['intro']),
    episodeCount: asInt(row['episode_count']),
    colorDominate: asString(row['color_dominate']),
    metaFetchedAt: asInt(row['meta_fetched_at']),
    lastReadAt: asInt(row['last_read_at']),
    episodeIndex: asInt(row['episode_index']),
    shelfAt: asInt(row['shelf_at']),
    shelfRemovedAt: asInt(row['shelf_removed_at']),
  );

  static Future<VideoRecord?> readVideo(
    DatabaseExecutor db,
    String id,
  ) async {
    if (id.isEmpty) return null;
    final rows = await db.rawQuery('$_videoSelect WHERE s.id = ? LIMIT 1', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _videoFromRow(rows.first);
  }

  static Future<List<VideoRecord>> readAllVideo(DatabaseExecutor db) async {
    final rows = await db.rawQuery('$_videoSelect ORDER BY s.id ASC');
    return rows.map(_videoFromRow).toList();
  }

  static Future<List<VideoRecord>> readVideoShelf(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery(
      '$_videoSelect '
      'WHERE s.shelf_at > 0 AND s.shelf_at > s.shelf_removed_at '
      'ORDER BY s.shelf_at DESC, s.id ASC',
    );
    return rows.map(_videoFromRow).toList();
  }

  static Future<List<VideoRecord>> readVideoRecent(
    DatabaseExecutor db,
    int limit,
  ) async {
    if (limit <= 0) return const [];
    final rows = await db.rawQuery(
      '$_videoSelect '
      'WHERE s.last_read_at > 0 '
      'ORDER BY s.last_read_at DESC, s.id ASC LIMIT ?',
      [limit],
    );
    return rows.map(_videoFromRow).toList();
  }

  static Future<void> writeVideo(
    DatabaseExecutor db,
    VideoRecord record,
  ) async {
    await db.insert(videoStateTable, {
      'id': record.id,
      'last_read_at': record.lastReadAt,
      'episode_index': record.episodeIndex,
      'shelf_at': record.shelfAt,
      'shelf_removed_at': record.shelfRemovedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert(videoMetaTable, {
      'id': record.id,
      'title': record.title,
      'cover': record.cover,
      'intro': record.intro,
      'episode_count': record.episodeCount,
      'color_dominate': record.colorDominate,
      'meta_fetched_at': record.metaFetchedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> pruneVideo(DatabaseExecutor db, int limit) async {
    await _prune(
      db,
      stateTable: videoStateTable,
      metaTable: videoMetaTable,
      limit: limit,
    );
  }

  static Future<void> _prune(
    DatabaseExecutor db, {
    required String stateTable,
    required String metaTable,
    required int limit,
  }) async {
    // 只数"可淘汰"的行。否则书架上有 500 本时，任何一条新进度都会被立刻挤掉。
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM $stateTable '
        'WHERE shelf_at = 0 AND shelf_removed_at = 0',
      ),
    );
    if (count == null || count <= limit) return;
    final excess = count - limit;
    await db.rawDelete(
      'DELETE FROM $stateTable WHERE id IN ('
      'SELECT id FROM $stateTable '
      'WHERE shelf_at = 0 AND shelf_removed_at = 0 '
      'ORDER BY last_read_at ASC, id ASC LIMIT ?)',
      [excess],
    );
    // 状态行没了，快照行也不该留着（否则书架/最近列表都读不到它，纯占空间）。
    await db.rawDelete(
      'DELETE FROM $metaTable WHERE id NOT IN (SELECT id FROM $stateTable)',
    );
  }

  // -------------------------------------------------------------------------
  // 从 shared_preferences 迁移（一次性）
  // -------------------------------------------------------------------------

  static Future<void> _migrateFromPreferences(Database db) async {
    final done = await db.query(
      kvTable,
      columns: ['v'],
      where: 'k = ?',
      whereArgs: [_prefsImportedKey],
      limit: 1,
    );
    if (done.isNotEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final novelLegacy = <String, dynamic>{
      'novelShelf': _decodeList(prefs.getString('shelf_books_v1')),
      'novelShelfMeta': _decodeMap(prefs.getString('novel_shelf_meta_v1')),
      'novelProgress': _decodeMap(prefs.getString('reading_progress_v1')),
    };
    final videoLegacy = <String, dynamic>{
      'videoShelf': _decodeList(prefs.getString('video_shelf_v1')),
      'videoShelfMeta': _decodeMap(prefs.getString('video_shelf_meta_v1')),
      'videoProgress': _decodeMap(prefs.getString('video_progress_v1')),
    };

    await db.transaction((txn) async {
      for (final record in novelRecordsFromLegacy(novelLegacy)) {
        await writeNovel(txn, record);
      }
      for (final record in videoRecordsFromLegacy(videoLegacy)) {
        await writeVideo(txn, record);
      }
      await txn.insert(kvTable, {
        'k': _prefsImportedKey,
        'v': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      return asMap(jsonDecode(raw)) ?? const {};
    } catch (_) {
      return const {};
    }
  }
}
