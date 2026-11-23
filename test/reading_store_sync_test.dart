import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/library_db.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';

/// 本地库的导出 / 合并（同步载荷 schemaVersion 3）。
///
/// 规则见 `docs/storage-model-proposal.md` §4：快照整组按 `metaFetchedAt`、
/// 进度整组按 `lastReadAt`、书架两列各取 max。
void main() {
  Map<String, dynamic> recordOf(Map<String, dynamic> data, {int index = 0}) =>
      (data['items'] as List)[index] as Map<String, dynamic>;

  test('导出是 items 数组，书架条目带 shelfAt', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final data = await store.exportSyncData();
    final items = data['items'] as List;
    expect(items, hasLength(1));
    final record = recordOf(data);
    expect(record['type'], 'novel');
    expect(record['id'], 'a');
    expect(record['title'], 'A');
    expect(record['shelfAt'], greaterThan(0));
    expect(record.containsKey('shelfRemovedAt'), isFalse);
  });

  test('pin 可切换、导出带 pinnedAt，取消后写 unpinnedAt 并同步', () async {
    final store = ReadingStore();
    await store.saveProgress(
      bookId: 'a',
      bookTitle: 'A',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    expect(await store.isPinned(LibraryType.novel, 'a'), isFalse);

    expect(
      await store.togglePin(type: LibraryType.novel, sourceId: 'a', title: 'A'),
      isTrue,
    );
    expect(await store.isPinned(LibraryType.novel, 'a'), isTrue);
    expect((await store.pinnedRecords()).map((r) => r.sourceId), ['a']);

    final pinnedRecord = recordOf(await store.exportSyncData());
    expect(pinnedRecord['pinnedAt'], greaterThan(0));
    expect(pinnedRecord.containsKey('unpinnedAt'), isFalse);

    await store.unpin(LibraryType.novel, 'a');
    expect(await store.isPinned(LibraryType.novel, 'a'), isFalse);
    expect(await store.pinnedRecords(), isEmpty);
    final unpinnedRecord = recordOf(await store.exportSyncData());
    expect(unpinnedRecord['unpinnedAt'], greaterThan(0));

    // 远端更新的一次 pin 能合并回来；远端没有 unpinnedAt 也不会复活取消。
    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'a',
          'title': 'A',
          'pinnedAt': DateTime.now().millisecondsSinceEpoch + 10000,
        },
      ],
    });
    expect(await store.isPinned(LibraryType.novel, 'a'), isTrue);

    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'a',
          'title': 'A',
          'pinnedAt': DateTime.now().millisecondsSinceEpoch + 10000,
          'unpinnedAt': DateTime.now().millisecondsSinceEpoch + 20000,
        },
      ],
    });
    expect(await store.isPinned(LibraryType.novel, 'a'), isFalse);
  });

  test('书架删除落成墓碑并清掉快照，书架不再显示', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    await store.removeFromShelf('a');

    expect(await store.shelfRecords(type: LibraryType.novel), isEmpty);

    final record = recordOf(await store.exportSyncData());
    expect(record['shelfRemovedAt'], greaterThan(0));
    // 墓碑瘦身：title/cover 全部清掉，行里只剩 id / 时间戳。
    expect(record.containsKey('title'), isFalse);
    expect(record.containsKey('cover'), isFalse);
  });

  test('远端新增收藏会合并进本地，远端删除也会生效', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'local', title: '本地'));

    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'remote',
          'title': '远端',
          'shelfAt': 10,
          'metaFetchedAt': 10,
        },
      ],
    });

    final shelf = await store.shelfRecords(type: LibraryType.novel);
    expect(shelf.map((r) => r.sourceId), containsAll(['local', 'remote']));

    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'local',
          'shelfRemovedAt': DateTime.now().millisecondsSinceEpoch + 10000,
        },
      ],
    });
    expect(
      (await store.shelfRecords(type: LibraryType.novel))
          .map((r) => r.sourceId),
      isNot(contains('local')),
    );
  });

  test('阅读进度按 lastReadAt 取较新的一条，旧远端不会覆盖本地', () async {
    final store = ReadingStore();
    await store.saveProgress(
      bookId: 'a',
      bookTitle: 'A',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 1,
      blockIndex: 2,
    );
    final local = await store.progress('a');
    expect(local, isNotNull);

    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'a',
          'title': 'A',
          'lastReadAt': 1,
          'chapterId': 'old',
        },
      ],
    });
    expect((await store.progress('a'))?.chapterId, local!.chapterId);

    await store.applySyncData({
      'items': [
        {
          'type': 'novel',
          'id': 'a',
          'title': 'A',
          'lastReadAt': local.updatedAt.millisecondsSinceEpoch + 10000,
          'chapterId': 'new',
          'chapterIndex': 8,
          'blockIndex': 4,
        },
      ],
    });
    expect((await store.progress('a'))?.chapterId, 'new');
    expect((await store.history(type: LibraryType.novel)).first.sourceId, 'a');
  });

  test('同 id 的小说与短剧互不影响（主键带类型前缀）', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: '42', title: '一本书'));
    await store.addVideoToShelf(const VideoSeries(id: '42', title: '一部剧'));

    expect(
      (await store.shelfRecords(type: LibraryType.novel)).map((r) => r.title),
      ['一本书'],
    );
    expect(
      (await store.shelfRecords(type: LibraryType.playlet)).map((r) => r.title),
      ['一部剧'],
    );
    expect(await store.isOnShelf('42'), isTrue);
    expect(await store.isVideoOnShelf('42'), isTrue);

    final records = (await store.exportSyncData())['items'] as List;
    expect(records, hasLength(2));
    expect(
      records.map((r) => (r as Map)['type']),
      containsAll(['novel', 'playlet']),
    );
  });

  test('短剧收藏和进度同样可合并', () async {
    final store = ReadingStore();
    await store.addVideoToShelf(
      const VideoSeries(id: 'v1', title: '剧一', episodeCount: 12),
    );
    await store.saveVideoProgress(seriesId: 'v1', title: '剧一', episodeIndex: 3);

    final record = recordOf(await store.exportSyncData());
    expect(record['type'], 'playlet');
    expect(record['episodeIndex'], 3);
    expect(record['episodeCount'], 12);

    await store.applySyncData({
      'items': [
        {
          'type': 'playlet',
          'id': 'v1',
          'title': '剧一',
          'lastReadAt': DateTime.now().millisecondsSinceEpoch + 10000,
          'episodeIndex': 8,
        },
      ],
    });
    expect((await store.videoProgress('v1'))?.episodeIndex, 8);
  });

  test('远端墓碑时间戳更新后要落盘，导出与远端一致（否则每次同步都互传）', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    await store.removeFromShelf('a');

    final localRemovedAt =
        recordOf(await store.exportSyncData())['shelfRemovedAt'] as int;
    final remoteRemovedAt = localRemovedAt + 1000;

    await store.applySyncData({
      'items': [
        {'type': 'novel', 'id': 'a', 'shelfRemovedAt': remoteRemovedAt},
      ],
    });

    expect(
      recordOf(await store.exportSyncData())['shelfRemovedAt'],
      remoteRemovedAt,
      reason: '取 max 之后的墓碑时间戳必须落盘，否则本地导出和远端永远差一个值',
    );
  });

  test('旧格式载荷（没有 items）不会被合并，避免按新结构误解旧数据', () async {
    final store = ReadingStore();
    final changed = await store.applySyncData({
      'novelShelf': [
        {'id': 'old', 'title': '旧书'},
      ],
    });
    expect(changed, isFalse);
    expect(await store.shelfRecords(type: LibraryType.novel), isEmpty);
  });

  test('墓碑不出现在历史里，未上架但读过的会出现', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'kept', title: '留下的'));
    await store.addToShelf(const NovelItem(id: 'gone', title: '移出的'));
    await store.saveProgress(
      bookId: 'kept',
      bookTitle: '留下的',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    await store.saveProgress(
      bookId: 'gone',
      bookTitle: '移出的',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    await store.saveProgress(
      bookId: 'loose',
      bookTitle: '没上架的',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    await store.removeFromShelf('gone');

    final history = await store.history(type: LibraryType.novel);
    expect(history.map((r) => r.sourceId), ['loose', 'kept']);
  });

  test('移出书架后继续读：回到历史并保留标题，但不加回书架', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'b', title: '追更中'));
    await store.saveProgress(
      bookId: 'b',
      bookTitle: '追更中',
      cover: '',
      chapterId: 'c1',
      chapterIndex: 0,
    );
    await store.removeFromShelf('b');
    expect(await store.history(type: LibraryType.novel), isEmpty);

    await store.saveProgress(
      bookId: 'b',
      bookTitle: '追更中',
      cover: '',
      chapterId: 'c2',
      chapterIndex: 1,
    );

    final history = await store.history(type: LibraryType.novel);
    expect(history.map((r) => r.sourceId), ['b']);
    expect(history.single.title, '追更中', reason: '重新开始读的书要能显示书名，不能被墓碑瘦身清空');
    expect(await store.isOnShelf('b'), isFalse, reason: '继续读不等于加回收藏');
  });

  test('裁剪墓碑：远端更旧的进度不会复活被淘汰的行', () {
    const local = LibraryRecord(
      type: LibraryType.novel,
      sourceId: 'x',
      progressPrunedAt: 300,
    );
    const remote = LibraryRecord(
      type: LibraryType.novel,
      sourceId: 'x',
      title: '被淘汰的旧书',
      lastReadAt: 200,
      progressRef: 'c1',
      progressIndex: 4,
    );

    final merged = mergeLibraryRecords(local, remote);
    expect(merged.hasProgress, isFalse, reason: '裁剪时间晚于对方进度，不能复活');
    expect(merged.progressPrunedAt, 300, reason: '裁剪事实要保留并同步出去');
    expect(merged.title, isEmpty, reason: '淘汰行不留快照');

    // 对方在裁剪之后又读过：进度更“新”，应当复活。
    final newer = remote.copyWith(lastReadAt: 400);
    final revived = mergeLibraryRecords(local, newer);
    expect(revived.progressRef, 'c1');
    expect(revived.lastReadAt, 400);
    expect(revived.title, '被淘汰的旧书');
  });

  test('prune 只写裁剪墓碑、不删行', () async {
    final db = await LibraryDb.instance();
    for (var i = 0; i < 3; i++) {
      await LibraryDb.write(
        db,
        LibraryRecord(
          type: LibraryType.novel,
          sourceId: 'b$i',
          title: '书$i',
          lastReadAt: 100 + i,
          progressRef: 'c$i',
          progressIndex: i,
        ),
      );
    }

    await LibraryDb.prune(db, 1, now: 999);

    final rows = await LibraryDb.readAll(db);
    expect(rows, hasLength(3), reason: '删行会让远端旧进度把条目补回来');
    final pruned = rows.where((r) => r.progressPrunedAt == 999).toList();
    expect(pruned, hasLength(2), reason: '超出额度的最旧两行被淘汰');
    expect(pruned.every((r) => !r.hasProgress), isTrue);
    expect(pruned.every((r) => r.title.isEmpty), isTrue);
    expect(
      rows.firstWhere((r) => r.sourceId == 'b2').hasProgress,
      isTrue,
      reason: '最新一条保留进度',
    );
  });

  group('从历史里删除一条', () {
    test('未收藏：清进度、写裁剪墓碑、快照瘦身', () async {
      final store = ReadingStore();
      await store.saveProgress(
        bookId: 'a',
        bookTitle: 'A',
        cover: 'https://example.com/a.jpg',
        chapterId: 'c1',
        chapterIndex: 2,
      );

      await store.removeHistory(LibraryType.novel, 'a');

      expect(await store.history(type: LibraryType.novel), isEmpty);
      expect(await store.progress('a'), isNull);
      final record = recordOf(await store.exportSyncData());
      expect(record['progressPrunedAt'], greaterThan(0));
      expect(record.containsKey('lastReadAt'), isFalse);
      expect(record.containsKey('title'), isFalse, reason: '不在收藏里的行不留快照');
    });

    test('在收藏里：只清历史，收藏快照保留', () async {
      final store = ReadingStore();
      await store.addToShelf(
        const NovelItem(
          id: 'a',
          title: 'A',
          cover: 'https://example.com/a.jpg',
        ),
      );
      await store.saveProgress(
        bookId: 'a',
        bookTitle: 'A',
        cover: 'https://example.com/a.jpg',
        chapterId: 'c1',
        chapterIndex: 2,
      );

      await store.removeHistory(LibraryType.novel, 'a');

      expect(await store.history(type: LibraryType.novel), isEmpty);
      final shelf = await store.shelfRecords(type: LibraryType.novel);
      expect(shelf.single.title, 'A');
      expect(shelf.single.cover, 'https://example.com/a.jpg');
      final record = recordOf(await store.exportSyncData());
      expect(record['progressPrunedAt'], greaterThan(0));
      expect(record['title'], 'A');
      expect(record['shelfAt'], greaterThan(0));
    });

    test('同步后远端旧进度不复活，裁剪之后的新进度才复活', () async {
      final store = ReadingStore();
      await store.saveProgress(
        bookId: 'a',
        bookTitle: 'A',
        cover: '',
        chapterId: 'c1',
        chapterIndex: 1,
      );
      await store.removeHistory(LibraryType.novel, 'a');
      final prunedAt =
          recordOf(await store.exportSyncData())['progressPrunedAt'] as int;

      await store.applySyncData({
        'items': [
          {
            'type': 'novel',
            'id': 'a',
            'title': 'A',
            'lastReadAt': prunedAt - 1000,
            'chapterId': 'old',
            'chapterIndex': 0,
          },
        ],
      });
      expect(
        await store.history(type: LibraryType.novel),
        isEmpty,
        reason: '删除历史是比旧进度更新的裁剪事实',
      );

      await store.applySyncData({
        'items': [
          {
            'type': 'novel',
            'id': 'a',
            'title': 'A',
            'lastReadAt': prunedAt + 1000,
            'chapterId': 'new',
            'chapterIndex': 8,
          },
        ],
      });
      final history = await store.history(type: LibraryType.novel);
      expect(history.single.progressRef, 'new', reason: '另一台设备裁剪后读过，应当复活');
    });

    test('短剧历史删除只 bump 短剧进度通道，不动收藏计数', () async {
      final store = ReadingStore();
      await store.addVideoToShelf(const VideoSeries(id: 'v1', title: '剧一'));
      await store.saveVideoProgress(
        seriesId: 'v1',
        title: '剧一',
        episodeIndex: 3,
      );

      final recentBefore = store.videoHistoryRevision.value;
      final shelfBefore = store.videoShelfRevision.value;
      await store.removeHistory(LibraryType.playlet, 'v1');

      expect(store.videoHistoryRevision.value, recentBefore + 1);
      expect(store.videoShelfRevision.value, shelfBefore);
      expect(await store.history(type: LibraryType.playlet), isEmpty);
      expect(await store.shelfRecords(type: LibraryType.playlet), hasLength(1));
    });
  });
}
