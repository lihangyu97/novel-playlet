import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('导出会给老书架补同步元数据', () async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1':
          '[{"id":"old","title":"旧书","cover":"","author":"","category":""}]',
    });
    final store = ReadingStore();
    final data = await store.exportSyncData();
    final meta = data['novelShelfMeta'] as Map;
    expect(meta['old'], {'u': 0, 'd': false});
  });

  test('书架删除会作为 tombstone 同步，远端旧条目不会复活', () async {
    final store = ReadingStore();
    const book = NovelItem(id: 'a', title: 'A');
    await store.addToShelf(book);
    await store.removeFromShelf('a');
    final local = await store.exportSyncData();
    final meta = local['novelShelfMeta'] as Map;
    expect(meta['a']['d'], isTrue);

    await store.applySyncData({
      'novelShelf': [book.toStorageJson()],
      'novelShelfMeta': {
        'a': {'u': 1, 'd': false},
      },
    });

    expect(await store.shelf(), isEmpty);
  });

  test('远端新增收藏会合并进本地，远端删除也会生效', () async {
    final store = ReadingStore();
    const local = NovelItem(id: 'local', title: '本地');
    const remote = NovelItem(id: 'remote', title: '远端');
    await store.addToShelf(local);

    await store.applySyncData({
      'novelShelf': [remote.toStorageJson()],
      'novelShelfMeta': {
        'remote': {'u': 10, 'd': false},
      },
    });

    final shelf = await store.shelf();
    expect(shelf.map((item) => item.id), containsAll(['local', 'remote']));

    await store.applySyncData({
      'novelShelfMeta': {
        'local': {
          'u': DateTime.now().millisecondsSinceEpoch + 10000,
          'd': true,
        },
      },
    });
    final afterDelete = await store.shelf();
    expect(afterDelete.map((item) => item.id), isNot(contains('local')));
  });

  test('阅读进度按 updatedAt 取较新的一条，旧远端不会覆盖本地', () async {
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
      'novelProgress': {
        'a': {
          'bookId': 'a',
          'bookTitle': 'A',
          'cover': '',
          'chapterId': 'old',
          'chapterIndex': 0,
          'blockIndex': 0,
          'updatedAt': 1,
        },
      },
    });
    expect((await store.progress('a'))?.chapterId, local!.chapterId);

    await store.applySyncData({
      'novelProgress': {
        'a': {
          'bookId': 'a',
          'bookTitle': 'A',
          'cover': '',
          'chapterId': 'new',
          'chapterIndex': 8,
          'blockIndex': 4,
          'updatedAt': local.updatedAt.millisecondsSinceEpoch + 10000,
        },
      },
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
    expect((data['videoShelf'] as List), hasLength(1));
    expect((data['videoProgress'] as Map)['v1']['episodeIndex'], 3);

    await store.applySyncData({
      'videoProgress': {
        'v1': {
          'seriesId': 'v1',
          'title': '剧一',
          'cover': '',
          'episodeIndex': 8,
          'updatedAt': DateTime.now().millisecondsSinceEpoch + 10000,
        },
      },
    });
    expect((await store.videoProgress('v1'))?.episodeIndex, 8);
  });
}
