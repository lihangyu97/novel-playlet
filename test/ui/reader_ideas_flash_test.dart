import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/reader/reader_bubble.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 回归：离线进入阅读页时，目录会在后台刷新，把章的 `version` 从空（离线
/// manifest 不存 version）换成网络目录里的值。
///
/// `chapterIdeasProvider` 的 family key 含 `itemVersion`，key 一变就重新请求；
/// 修复前 UI 直接 `value ?? empty`，已经画出来的段评气泡会先消失再出现。
/// 这里逐帧断言气泡不断档。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('离线目录后台刷新 version 变化时段评气泡不消失', (tester) async {
    await loadPreviewFont();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 目录故意比 idea list 慢：气泡先画出来，目录刷新后才换 version。
    final transport = _FlashTransport(
      directoryDelay: const Duration(milliseconds: 40),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(transport)),
          readerChapterCacheProvider.overrideWithValue(PreviewChapterCache()),
          offlineBookStoreProvider.overrideWithValue(_FakeOfflineStore()),
          offlineSeriesStoreProvider.overrideWithValue(
            EmptyOfflineSeriesStore(),
          ),
        ],
        child: const PreviewApp(
          home: ReaderPage(
            args: ReaderArgs(bookId: 'offline-book', bookTitle: '离线书'),
          ),
        ),
      ),
    );

    // 等第一波气泡（离线老正文补锚点 + idea list 返回）画出来。
    var appeared = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 5));
      if (find.byType(ReaderParagraphBubble).evaluate().isNotEmpty) {
        appeared = true;
        break;
      }
    }
    expect(appeared, isTrue, reason: '离线老正文补锚点后应画出段评气泡');

    // 之后目录刷新把 version 换成网络值、汇总重新请求：任何一帧都不能没有气泡。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 5));
      expect(
        find.byType(ReaderParagraphBubble),
        findsWidgets,
        reason: '第 $i 帧气泡消失（版本变化重新请求期间不能清空汇总）',
      );
    }
  });
}

/// 目录响应带 `version`、其余接口沿用预览假数据。
class _FlashTransport extends FakePreviewTransport {
  _FlashTransport({required this.directoryDelay});

  final Duration directoryDelay;

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    if (path.contains('/directory')) {
      await Future<void>.delayed(directoryDelay);
      return _json({
        'code': 0,
        'data': {
          'item_data_list': [
            {
              'item_id': 'c1',
              'title': '第1章',
              // 离线 manifest 里没有 version，网络目录里才有：key 变化来源。
              'version': 'v-network',
              'volume_name': '第一卷',
            },
          ],
        },
      });
    }
    return super.send(method, path, query: query, body: body, timeout: timeout);
  }

  BackendResponse _json(Map<String, Object?> payload) => BackendResponse(
    200,
    Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    'application/json',
  );
}

/// 已整本下载的离线书：manifest 只有一章，正文本地落盘且没有段落锚点
/// （升级前下载的老文件）。
class _FakeOfflineStore extends OfflineBookStore {
  _FakeOfflineStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  @override
  Future<OfflineBook?> read(String bookId) async => OfflineBook(
    bookId: bookId,
    title: '离线书',
    chapters: const [OfflineChapter(id: 'c1', title: '第1章', index: 0)],
  );

  @override
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async =>
      ChapterContent(
        id: chapterId,
        title: '第1章',
        paragraphs: const ['这是升级前下载的离线正文第一段，没有段落锚点，用来复现气泡闪动。'],
      );

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() async => const OfflineStats(
    count: 1,
    bytes: 1024,
    capBytes: OfflineBookStore.novelCapBytes,
  );
}
