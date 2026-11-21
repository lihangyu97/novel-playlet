import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/models/json_utils.dart';
import 'library_records.dart';

/// 书架 / 收藏 / 进度的本地库（SQLite）。
///
/// **一张表**：小说与短剧共用 `library`，靠 `type` 区分；主键是 `key`
/// （`'$type/$id'`），因为两类内容的上游 id 来自不同域、裸 id 可能撞号。
///
/// 字段按生命周期分组：快照（加入书架时写一次）、进度（翻页就写）、书架
/// 两列时间戳。移出书架且之后没再读的墓碑行由 [LibraryRecord.normalized]
/// 清掉快照；移出后继续读的保留快照（还在历史里），行本身永不删。
///
/// 测试用 [overridePath] 注入 `inMemoryDatabasePath`（见
/// `test/support/library_test_db.dart`）；生产路径是
/// `<Application Support>/library.db`。
class LibraryDb {
  LibraryDb._();

  static const int schemaVersion = 3;

  static const String table = 'library';
  static const String kvTable = 'kv';

  /// 「历史」的取行条件：读过，且不是"移出书架后没再读"的墓碑。
  static const String _historyWhere =
      'last_read_at > 0 AND ('
      'shelf_removed_at = 0 OR shelf_at > shelf_removed_at '
      'OR last_read_at > shelf_removed_at)';

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

  /// 关掉当前连接。测试用它重置内存库（关掉即销毁）。
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
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: (db, _) => _createSchema(db),
      onUpgrade: (db, from, _) async {
        // **已经是最新的库绝不能走重建**：那等于每次升版本都清空用户书架。
        // 以后继续升版本时，在这里按 from 逐级写增量迁移。
        if (from >= schemaVersion) return;
        if (from < 2) {
          // v1 是"状态/快照拆两张表"的版本，从未正式发布过；直接重建。
          for (final name in [
            'novel_state',
            'novel_meta',
            'video_state',
            'video_meta',
          ]) {
            await db.execute('DROP TABLE IF EXISTS $name');
          }
          await db.execute('DROP TABLE IF EXISTS $table');
          await _createSchema(db);
          return;
        }
        if (from == 2) {
          // v2 → v3：加进度裁剪墓碑列；已有行默认 0（没淘汰过）。
          await db.execute(
            'ALTER TABLE $table ADD COLUMN progress_pruned_at '
            'INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }

  static Future<String> _defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/library.db';
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE $table (
        key TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        intro TEXT NOT NULL DEFAULT '',
        episode_count INTEGER NOT NULL DEFAULT 0,
        color_dominate TEXT NOT NULL DEFAULT '',
        meta_fetched_at INTEGER NOT NULL DEFAULT 0,
        last_read_at INTEGER NOT NULL DEFAULT 0,
        progress_ref TEXT NOT NULL DEFAULT '',
        progress_index INTEGER NOT NULL DEFAULT 0,
        progress_sub INTEGER NOT NULL DEFAULT 0,
        progress_pruned_at INTEGER NOT NULL DEFAULT 0,
        shelf_at INTEGER NOT NULL DEFAULT 0,
        shelf_removed_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $kvTable (
        k TEXT PRIMARY KEY,
        v TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX library_recent ON $table(last_read_at DESC)',
    );
    await db.execute('CREATE INDEX library_shelf ON $table(shelf_at DESC)');
    await db.execute('CREATE INDEX library_type ON $table(type)');
  }

  static LibraryRecord _fromRow(Map<String, Object?> row) => LibraryRecord(
    type: LibraryType.tryParse(row['type']) ?? LibraryType.novel,
    sourceId: asString(row['source_id']),
    title: asString(row['title']),
    author: asString(row['author']),
    cover: asString(row['cover']),
    intro: asString(row['intro']),
    episodeCount: asInt(row['episode_count']),
    colorDominate: asString(row['color_dominate']),
    metaFetchedAt: asInt(row['meta_fetched_at']),
    lastReadAt: asInt(row['last_read_at']),
    progressRef: asString(row['progress_ref']),
    progressIndex: asInt(row['progress_index']),
    progressSub: asInt(row['progress_sub']),
    progressPrunedAt: asInt(row['progress_pruned_at']),
    shelfAt: asInt(row['shelf_at']),
    shelfRemovedAt: asInt(row['shelf_removed_at']),
  );

  static Future<LibraryRecord?> read(
    DatabaseExecutor db,
    LibraryType type,
    String sourceId,
  ) async {
    if (sourceId.isEmpty) return null;
    final rows = await db.query(
      table,
      where: 'key = ?',
      whereArgs: ['${type.wire}/$sourceId'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// 导出用：按主键排序，保证同一份数据每次序列化出的字符串完全一致
  /// （同步层靠字符串比较决定要不要上传，顺序不稳会白传）。
  static Future<List<LibraryRecord>> readAll(DatabaseExecutor db) async {
    final rows = await db.query(table, orderBy: 'key ASC');
    return rows.map(_fromRow).toList();
  }

  /// 在架条目（书架 / 收藏），按加架时间倒序。
  ///
  /// [limit] 为空时取全部；我的页预览只取前几个，全量列表弹窗再放开。
  static Future<List<LibraryRecord>> readShelf(
    DatabaseExecutor db, {
    LibraryType? type,
    int? limit,
  }) async {
    if (limit != null && limit <= 0) return const [];
    final where = StringBuffer('shelf_at > 0 AND shelf_at > shelf_removed_at');
    final args = <Object?>[];
    if (type != null) {
      where.write(' AND type = ?');
      args.add(type.wire);
    }
    final rows = await db.query(
      table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'shelf_at DESC, key ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// 在架条数（书架 / 收藏）。只算个数、不取行。
  static Future<int> countShelf(
    DatabaseExecutor db, {
    LibraryType? type,
  }) async {
    final where = StringBuffer('shelf_at > 0 AND shelf_at > shelf_removed_at');
    final args = <Object?>[];
    if (type != null) {
      where.write(' AND type = ?');
      args.add(type.wire);
    }
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $table WHERE $where', args),
    );
    return count ?? 0;
  }

  /// 「历史」：读过且当前不是墓碑（移出书架的不再出现在历史里）。
  ///
  /// 例外是"移出后又读过"的行：`last_read_at > shelf_removed_at` 说明用户还在
  /// 追这本书，要留在历史里（[LibraryRecord.normalized] 也会为它保留快照）。
  ///
  /// [limit] 为空时取全部。
  static Future<List<LibraryRecord>> readHistory(
    DatabaseExecutor db, {
    int? limit,
    LibraryType? type,
  }) async {
    if (limit != null && limit <= 0) return const [];
    final where = StringBuffer(_historyWhere);
    final args = <Object?>[];
    if (type != null) {
      where.write(' AND type = ?');
      args.add(type.wire);
    }
    final rows = await db.query(
      table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'last_read_at DESC, key ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// 历史条数（不含墓碑）。页头统计用，只算个数、不取行。
  static Future<int> countHistory(DatabaseExecutor db) async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM $table WHERE $_historyWhere'),
    );
    return count ?? 0;
  }

  /// 整条写回；墓碑行会先经过 [LibraryRecord.normalized] 清掉快照。
  static Future<void> write(DatabaseExecutor db, LibraryRecord record) async {
    final row = record.normalized();
    await db.insert(table, {
      'key': row.key,
      'type': row.type.wire,
      'source_id': row.sourceId,
      'title': row.title,
      'author': row.author,
      'cover': row.cover,
      'intro': row.intro,
      'episode_count': row.episodeCount,
      'color_dominate': row.colorDominate,
      'meta_fetched_at': row.metaFetchedAt,
      'last_read_at': row.lastReadAt,
      'progress_ref': row.progressRef,
      'progress_index': row.progressIndex,
      'progress_sub': row.progressSub,
      'progress_pruned_at': row.progressPrunedAt,
      'shelf_at': row.shelfAt,
      'shelf_removed_at': row.shelfRemovedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 收敛记录条数：只淘汰"没上架过、也没有墓碑"的纯进度行，最旧的先走。
  ///
  /// 小说与短剧**共用一个额度**。书架条目与墓碑永远不删行：移出书架只是写
  /// `shelf_removed_at`，删行会丢掉"删除"这个事实，远端旧值随即把条目复活。
  ///
  /// 淘汰也不删行，而是把进度清空、写 `progress_pruned_at`。删行的话远端那份
  /// 旧进度会在下次同步把条目补回来；有了裁剪时间，合并时才能判断"这是被淘汰
  /// 的旧值，还是对方真的又读了一遍"（见 [mergeLibraryRecords]）。
  static Future<void> prune(
    DatabaseExecutor db,
    int limit, {
    required int now,
  }) async {
    // 只数"可淘汰"的行：书架、墓碑、已经淘汰过的标记都不占额度。
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM $table '
        'WHERE shelf_at = 0 AND shelf_removed_at = 0 '
        'AND last_read_at > 0',
      ),
    );
    if (count == null || count <= limit) return;
    final excess = count - limit;
    // 先取 key 再更新：UPDATE 的子查询会边算边改，先固定一份列表更稳。
    final rows = await db.rawQuery(
      'SELECT key FROM $table '
      'WHERE shelf_at = 0 AND shelf_removed_at = 0 AND last_read_at > 0 '
      'ORDER BY last_read_at ASC, key ASC LIMIT ?',
      [excess],
    );
    for (final row in rows) {
      await db.rawUpdate(
        'UPDATE $table SET '
        'last_read_at = 0, progress_ref = \'\', progress_index = 0, '
        'progress_sub = 0, progress_pruned_at = ?, '
        'title = \'\', author = \'\', cover = \'\', intro = \'\', '
        'episode_count = 0, color_dominate = \'\', meta_fetched_at = 0 '
        'WHERE key = ?',
        [now, asString(row['key'])],
      );
    }
  }
}
