import 'package:flutter_test/flutter_test.dart';
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
}
