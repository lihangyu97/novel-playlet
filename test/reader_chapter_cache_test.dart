import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';

/// 缓存 schema 兼容：段评锚点（`paraIndices`）是后加的字段，老文件没有。
/// 命中老缓存时必须标记 `anchorsOutdated`，让阅读页补取一次带锚点的正文，
/// 否则段评气泡会一直等到 7 天过期才出现。
void main() {
  late Directory support;
  late ReaderChapterCache cache;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('reader_chapter_cache');
    cache = ReaderChapterCache(supportDirectory: () async => support);
  });

  tearDown(() async {
    if (support.existsSync()) {
      await support.delete(recursive: true);
    }
  });

  File cacheFile(String chapterId) => File(
    '${support.path}/reader_chapters/'
    '${base64Url.encode(utf8.encode(chapterId)).replaceAll('=', '')}.json',
  );

  test('老 schema（无 v / 无锚点）命中后标记 anchorsOutdated', () async {
    cacheFile('c1')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'id': 'c1',
          'title': '第1章',
          'paragraphs': ['第一段', '第二段'],
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );

    final hit = (await cache.get('c1'))!;
    expect(hit.content.paragraphs, ['第一段', '第二段']);
    expect(hit.isStale, isFalse, reason: '抓取时间新，不该按时间过期');
    expect(hit.content.paraIndices, isEmpty);
    expect(hit.anchorsOutdated, isTrue, reason: '老缓存要补取一次正文');
  });

  test('新写入的缓存带 schema 版本与锚点', () async {
    await cache.put(
      const ChapterContent(
        id: 'c2',
        title: '第2章',
        paragraphs: ['第一段', '第二段'],
        paraIndices: [7, 8],
      ),
    );

    final hit = (await cache.get('c2'))!;
    expect(hit.content.paraIndices, [7, 8]);
    expect(hit.anchorsOutdated, isFalse);

    final json = jsonDecode(await cacheFile('c2').readAsString()) as Map;
    expect(json['v'], ReaderChapterCache.schemaVersion);
  });

  test('新版缓存即使没有锚点也不再触发补取', () async {
    await cache.put(
      const ChapterContent(
        id: 'c3',
        title: '第3章',
        paragraphs: ['纯文本源没有锚点'],
      ),
    );

    final hit = (await cache.get('c3'))!;
    expect(hit.anchorsOutdated, isFalse, reason: '写回新 schema 后不再重试');
  });

  test('锚点长度与段落数对不上时当无锚点', () async {
    cacheFile('c4')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'v': ReaderChapterCache.schemaVersion,
          'id': 'c4',
          'title': '第4章',
          'paragraphs': ['第一段', '第二段'],
          'paraIndices': [9],
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );

    final hit = (await cache.get('c4'))!;
    expect(hit.content.paraIndices, isEmpty);
    expect(hit.anchorsOutdated, isFalse, reason: 'schema 已新，只当无锚点');
  });
}
