import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';

/// 小说离线区存储：manifest / 章节 JSON / 统计 / 校正 / 自愈。
void main() {
  late Directory tempRoot;
  late OfflinePaths paths;
  late OfflineBookStore store;

  setUp(() async {
    // 每个用例独立临时目录，绝不碰真实 App 目录。
    tempRoot = await Directory.systemTemp.createTemp('offline_book_test_');
    paths = OfflinePaths(rootDirectory: () async => tempRoot);
    store = OfflineBookStore(paths: paths);
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
  });

  OfflineBook book({
    String bookId = 'b1',
    int chapters = 3,
    int completed = 0,
    int bytes = 0,
  }) => OfflineBook(
    bookId: bookId,
    title: '测试书',
    cover: 'https://example.com/cover.jpg',
    chapters: [
      for (var i = 0; i < chapters; i++)
        OfflineChapter(id: 'c$i', title: '第${i + 1}章', index: i),
    ],
    completed: completed,
    bytes: bytes,
  );

  ChapterContent content(String id) =>
      ChapterContent(id: id, title: '标题$id', paragraphs: ['正文$id']);

  test('begin 写完整 manifest，read 原样读回', () async {
    await store.begin(book());
    final loaded = await store.read('b1');
    expect(loaded, isNotNull);
    expect(loaded!.bookId, 'b1');
    expect(loaded.title, '测试书');
    expect(loaded.total, 3);
    expect(loaded.chapters.map((c) => c.id), ['c0', 'c1', 'c2']);
    expect(loaded.schema, offlineSchema);
    expect(loaded.kind, offlineKindNovel);
  });

  test('写章 / 读章：与自动层同一 JSON 结构', () async {
    await store.begin(book());
    final written = await store.writeChapter('b1', content('c1'));
    expect(written, greaterThan(0));

    final hit = await store.readChapter('b1', 'c1');
    expect(hit, isNotNull);
    expect(hit!.title, '标题c1');
    expect(hit.paragraphs, ['正文c1']);

    // 落盘结构：v/id/title/paragraphs/fetchedAt（v = 章节缓存 schema 版本）。
    final raw = jsonDecode(
      await (await store.chapterFile('b1', 'c1')).readAsString(),
    );
    expect(raw['v'], chapterCacheSchemaVersion);
    expect(raw['id'], 'c1');
    expect(raw['paragraphs'], ['正文c1']);
    expect(raw['fetchedAt'], isA<int>());
  });

  test('损坏章节文件读作 miss 并把坏文件删掉', () async {
    await store.begin(book());
    final file = await store.chapterFile('b1', 'c1');
    await file.parent.create(recursive: true);
    await file.writeAsString('{not valid json');

    expect(await store.readChapter('b1', 'c1'), isNull);
    expect(await file.exists(), isFalse, reason: '坏文件应自愈删除');
  });

  test('missingChapterIds 只看文件是否存在', () async {
    await store.begin(book());
    await store.writeChapter('b1', content('c0'));
    await store.writeChapter('b1', content('c2'));
    final missing = await store.missingChapterIds('b1', [
      const Chapter(id: 'c0', title: '一'),
      const Chapter(id: 'c1', title: '二'),
      const Chapter(id: 'c2', title: '三'),
    ]);
    expect(missing, ['c1']);
  });

  test('stats 只累加 manifest 的 bytes 与条数', () async {
    await store.begin(book(bookId: 'b1', bytes: 100));
    await store.begin(book(bookId: 'b2', bytes: 250));
    final stats = await store.stats();
    expect(stats.count, 2);
    expect(stats.bytes, 350);
    expect(stats.capBytes, OfflineBookStore.novelCapBytes);
    expect(OfflineBookStore.novelCapBytes, 1024 * 1024 * 1024);
  });

  test('reconcile 按文件存在校正 completed / bytes', () async {
    await store.begin(book(completed: 0, bytes: 0));
    await store.writeChapter('b1', content('c0'));
    await store.writeChapter('b1', content('c1'));

    await store.reconcile('b1');
    final loaded = await store.read('b1');
    expect(loaded!.completed, 2);
    expect(loaded.bytes, greaterThan(0));
    expect(loaded.total, 3);
  });

  test('summaries 只读 manifest，孤儿目录被跳过', () async {
    await store.begin(book(bookId: 'b1', completed: 1));
    // 手工造一个没有 book.json 的孤立目录（崩溃残留）。
    final orphan = await paths.bookDir('orphan');
    await orphan.create(recursive: true);

    final summaries = await store.summaries();
    expect(summaries.map((s) => s.bookId), ['b1']);
  });

  test('pruneOrphans 清理无 manifest 的目录与残留 .part', () async {
    await store.begin(book(bookId: 'b1'));
    final orphan = await paths.bookDir('orphan');
    await orphan.create(recursive: true);
    final part = File('${(await paths.bookDir('b1')).path}/x.json.part');
    await part.writeAsString('half');

    final removed = await store.pruneOrphans();
    expect(removed, 1);
    expect(await orphan.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(await store.read('b1'), isNotNull, reason: '正常书不能被误删');
  });

  test('cleanupPartFiles 只清残留 .part（启动恢复用）', () async {
    await store.begin(book(bookId: 'b1'));
    final dir = await paths.bookDir('b1');
    final part = File('${dir.path}/c0.json.123.part');
    await part.writeAsString('half');
    final keep = File('${dir.path}/keep.json');
    await keep.writeAsString('{}');

    await store.cleanupPartFiles();
    expect(await part.exists(), isFalse);
    expect(await keep.exists(), isTrue, reason: '正式文件不能被误删');
    expect(await store.read('b1'), isNotNull);
  });

  test('delete / clearAll 只动小说区', () async {
    await store.begin(book(bookId: 'b1'));
    await store.begin(book(bookId: 'b2'));
    await store.delete('b1');
    expect(await store.read('b1'), isNull);
    expect(await store.read('b2'), isNotNull);

    await store.clearAll();
    expect(await store.read('b2'), isNull);
    expect(await store.summaries(), isEmpty);
  });

  test('schema 不认识当没有缓存（不删文件）', () async {
    final dir = await paths.bookDir('b9');
    await dir.create(recursive: true);
    await File('${dir.path}/book.json').writeAsString(
      jsonEncode({'schema': 99, 'kind': 'novel', 'bookId': 'b9'}),
    );
    expect(await store.read('b9'), isNull);
    expect(await File('${dir.path}/book.json').exists(), isTrue);
  });

  test('未缓存的书 read/missing 都安全返回', () async {
    expect(await store.read('nope'), isNull);
    expect(await store.readChapter('nope', 'c1'), isNull);
    expect(
      await store.missingChapterIds('nope', [
        const Chapter(id: 'c1', title: '一'),
      ]),
      ['c1'],
    );
  });
}
