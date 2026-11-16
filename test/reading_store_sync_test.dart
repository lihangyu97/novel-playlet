import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';

/// 本地库的导出 / 合并（同步载荷 schemaVersion 2）。
///
/// 规则见 `docs/storage-model-proposal.md` §4：快照整组按 `metaFetchedAt`、
/// 进度整组按 `lastReadAt`、书架两列各取 max。
void main() {
  test('导出是 v2 记录数组，书架条目带 shelfAt', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final data = await store.exportSyncData();
    final novels = data['novel'] as List;
    expect(novels, hasLength(1));
    final record = novels.single as Map;
    expect(record['id'], 'a');
    expect(record['title'], 'A');
    expect(record['shelfAt'], greaterThan(0));
    expect(record.containsKey('shelfRemovedAt'), isFalse);
    expect(data['video'], isEmpty);
  });

  test('书架删除会落成 shelfRemovedAt，远端旧条目不会复活', () async {
    final store = ReadingStore();
    const book = NovelItem(id: 'a', title: 'A');
    await store.addToShelf(book);
    await store.removeFromShelf('a');

    final local = await store.exportSyncData();
    final record = (local['novel'] as List).single as Map;
    expect(record['shelfRemovedAt'], greaterThan(0));

    // 远端的加入时间更早：max 之后仍然是"删除态"。
    await store.applySyncData({
      'novel': [
        {'id': 'a', 'title': 'A', 'shelfAt': 1, 'metaFetchedAt': 1},
      ],
      'video': <Object>[],
    });

    expect(await store.shelf(), isEmpty);
  });

  test('远端新增收藏会合并进本地，远端删除也会生效', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'local', title: '本地'));

    await store.applySyncData({
      'novel': [
        {
          'id': 'remote',
          'title': '远端',
          'shelfAt': 10,
          'metaFetchedAt': 10,
        },
      ],
      'video': <Object>[],
    });

    final shelf = await store.shelf();
    expect(shelf.map((item) => item.id), containsAll(['local', 'remote']));

    await store.applySyncData({
      'novel': [
        {
          'id': 'local',
          'shelfRemovedAt': DateTime.now().millisecondsSinceEpoch + 10000,
        },
      ],
      'video': <Object>[],
    });
    expect((await store.shelf()).map((item) => item.id), isNot(contains('local')));
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
      'novel': [
        {'id': 'a', 'title': 'A', 'lastReadAt': 1, 'chapterId': 'old'},
      ],
      'video': <Object>[],
    });
    expect((await store.progress('a'))?.chapterId, local!.chapterId);

    await store.applySyncData({
      'novel': [
        {
          'id': 'a',
          'title': 'A',
          'lastReadAt': local.updatedAt.millisecondsSinceEpoch + 10000,
          'chapterId': 'new',
          'chapterIndex': 8,
          'blockIndex': 4,
        },
      ],
      'video': <Object>[],
    });
    expect((await store.progress('a'))?.chapterId, 'new');
    expect((await store.recent()).first.bookId, 'a');
  });

  test('短剧收藏和进度同样可合并', () async {
    final store = ReadingStore();
    const series = VideoSeries(id: 'v1', title: '剧一', episodeCount: 12);
    await store.addVideoToShelf(series);
    await store.saveVideoProgress(seriesId: 'v1', title: '剧一', episodeIndex: 3);

    final data = await store.exportSyncData();
    final videos = data['video'] as List;
    expect(videos, hasLength(1));
    expect((videos.single as Map)['episodeIndex'], 3);

    await store.applySyncData({
      'video': [
        {
          'id': 'v1',
          'title': '剧一',
          'lastReadAt': DateTime.now().millisecondsSinceEpoch + 10000,
          'episodeIndex': 8,
        },
      ],
      'novel': <Object>[],
    });
    expect((await store.videoProgress('v1'))?.episodeIndex, 8);
  });

  test('远端墓碑时间戳更新后要落盘，导出与远端一致（否则每次同步都互传）', () async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    await store.removeFromShelf('a');

    final before = ((await store.exportSyncData())['novel'] as List).single as Map;
    final localRemovedAt = before['shelfRemovedAt'] as int;
    final remoteRemovedAt = localRemovedAt + 1000;

    await store.applySyncData({
      'novel': [
        {'id': 'a', 'shelfRemovedAt': remoteRemovedAt},
      ],
      'video': <Object>[],
    });

    final after = ((await store.exportSyncData())['novel'] as List).single as Map;
    expect(
      after['shelfRemovedAt'],
      remoteRemovedAt,
      reason: '取 max 之后的墓碑时间戳必须落盘，否则本地导出和远端永远差一个值',
    );
  });

  test('v1 旧载荷（novelShelf / novelProgress）也能合并，升级不丢数据', () async {
    final store = ReadingStore();
    const book = NovelItem(id: 'old', title: '旧书', author: '某作者');
    await store.applySyncData({
      'novelShelf': [book.toStorageJson()],
      'novelShelfMeta': {
        'old': {'u': 5, 'd': false},
      },
      'novelProgress': {
        'old': {
          'bookId': 'old',
          'bookTitle': '旧书',
          'cover': '',
          'chapterId': 'c9',
          'chapterIndex': 9,
          'blockIndex': 1,
          'updatedAt': 7,
        },
      },
    });

    final shelf = await store.shelf();
    expect(shelf.map((item) => item.id), ['old']);
    expect(shelf.single.author, '某作者');
    final progress = await store.progress('old');
    expect(progress?.chapterId, 'c9');
    expect(progress?.blockIndex, 1);
  });
}
