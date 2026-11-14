import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/widgets/detail_circle_button.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/cache/cache_center_page.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_queue.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';
import 'package:novel_playlet/features/cache/widgets/offline_download_button.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/preview_harness.dart';

/// 小说详情页的离线集成（docs/implementation.md）：
/// - 网络失败时详情回退离线 manifest（书名/封面/目录），还能点章节进阅读；
/// - 底部「缓存整本」按钮三态：未缓存 / 已缓存 / 进行中（暂停）。
///
/// 离线存储全部用内存假实现：widget test 里 path_provider 没有平台实现，真实
/// 离线目录的 IO Future 永远不会完成（与 [EmptyOfflineBookStore] 同因）。
/// 按读屏文案定位底栏圆形按钮（按钮只有图标，没有可见文字）。
Finder circleButton(String semanticLabel) => find.byWidgetPredicate(
  (widget) =>
      widget is DetailCircleButton && widget.semanticLabel == semanticLabel,
);

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpDetail(
    WidgetTester tester, {
    required BackendTransport transport,
    required OfflineBookStore bookStore,
    required OfflineSeriesStore seriesStore,
    OfflineTaskStore? taskStore,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(transport)),
          offlineBookStoreProvider.overrideWithValue(bookStore),
          offlineSeriesStoreProvider.overrideWithValue(seriesStore),
          readerChapterCacheProvider.overrideWithValue(PreviewChapterCache()),
          if (taskStore != null)
            offlineTaskStoreProvider.overrideWithValue(taskStore),
        ],
        child: const PreviewApp(home: DetailPage(bookId: '1')),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  /// 点缓存入口后只推进固定时长，不用 pumpAndSettle：缓存中心页可能有
  /// 不确定进度的下载动画/异步列表，settle 会一直等不到静止。
  Future<void> openCacheCenter(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('详情页网络失败时回退离线 manifest：书名/目录可用，且能进阅读', (tester) async {
    final bookStore = _MemoryBookStore()..seedOfflineBook();
    await pumpDetail(
      tester,
      transport: _DownTransport(),
      bookStore: bookStore,
      seriesStore: _MemorySeriesStore(),
    );

    expect(find.text('离线剑来'), findsWidgets, reason: '书名应来自离线 manifest');
    expect(find.text('共 3 章 · 查看全部'), findsOneWidget);
    expect(find.text('离线第1章'), findsWidgets);
    // 整本已缓存 → 缓存入口是「已缓存」态（图标 + 读屏文案）。
    expect(circleButton('已缓存'), findsOneWidget);
    expect(find.byIcon(Icons.download_done_outlined), findsOneWidget);
    expect(circleButton('收藏'), findsOneWidget);

    // 断网也能从详情点章节进阅读，正文直接来自离线区。
    await tester.tap(find.text('离线第1章').first);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.textContaining('离线正文 c0'), findsWidgets);
  });

  testWidgets('详情页下载按钮-未缓存：展示下载入口且不挤压书架/开始阅读', (tester) async {
    await pumpDetail(
      tester,
      transport: FakePreviewTransport(),
      bookStore: _MemoryBookStore(),
      seriesStore: _MemorySeriesStore(),
    );

    expect(find.byType(OfflineDownloadButton), findsOneWidget);
    expect(circleButton('缓存'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    // 左收藏、中缓存、右主按钮三颗都在，按钮只有图标，状态文案走读屏。
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });

  testWidgets('详情页下载按钮-已缓存：点击进缓存中心页', (tester) async {
    final bookStore = _MemoryBookStore()..seedOfflineBook(completed: 3);
    await pumpDetail(
      tester,
      transport: FakePreviewTransport(),
      bookStore: bookStore,
      seriesStore: _MemorySeriesStore(),
    );

    expect(circleButton('已缓存'), findsOneWidget);
    await openCacheCenter(tester, find.byIcon(Icons.download_done_outlined));
    expect(find.byType(CacheCenterPage), findsOneWidget);
    expect(
      find.text('已离线缓存，可在 设置 → 存储 管理'),
      findsNothing,
      reason: '已缓存不再弹旧 SnackBar，而是进缓存中心',
    );
  });

  testWidgets('详情页下载按钮-进行中：显示「缓存中」并进缓存中心页', (tester) async {
    final task = OfflineTask(
      kind: OfflineTaskKind.novel,
      id: '1',
      title: '离线剑来',
      completed: 66,
      total: 320,
      status: OfflineTaskStatus.paused,
    );
    await pumpDetail(
      tester,
      transport: FakePreviewTransport(),
      bookStore: _MemoryBookStore(),
      seriesStore: _MemorySeriesStore(),
      taskStore: _FixedTaskStore(task),
    );

    expect(find.byType(OfflineDownloadButton), findsOneWidget);
    expect(circleButton('缓存中'), findsOneWidget, reason: '暂停任务也算缓存中');
    expect(find.byIcon(Icons.downloading_outlined), findsOneWidget);
    // 不再显示旧的环形进度 + 百分比。
    expect(find.text('21%'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(OfflineDownloadButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );

    await openCacheCenter(tester, find.byIcon(Icons.downloading_outlined));
    expect(find.byType(CacheCenterPage), findsOneWidget);
  });

  testWidgets('详情页下载按钮-已排队：显示「缓存中」并进缓存中心页', (tester) async {
    await pumpDetail(
      tester,
      transport: FakePreviewTransport(),
      bookStore: _MemoryBookStore(),
      seriesStore: _MemorySeriesStore(),
    );
    expect(circleButton('缓存'), findsOneWidget);

    // 单任务下载器正跑别的任务时，本书的缓存请求会入队；等它开始前详情按钮
    // 也要显示「缓存中」，而不是还能重复点「缓存」。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DetailPage)),
    );
    container
        .read(offlineQueueProvider.notifier)
        .enqueue(
          OfflineQueueJob(
            kind: OfflineTaskKind.novel,
            id: '1',
            title: '离线剑来',
            cover: '',
            items: const [],
          ),
        );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(circleButton('缓存中'), findsOneWidget, reason: '已排队也算缓存中');
    expect(find.byIcon(Icons.downloading_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    await openCacheCenter(tester, find.byIcon(Icons.downloading_outlined));
    expect(find.byType(CacheCenterPage), findsOneWidget);
  });
}

/// 测试用空网络：所有请求都 500，模拟断网。
class _DownTransport extends BackendTransport {
  _DownTransport() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async => BackendResponse(
    500,
    Uint8List.fromList(utf8.encode(jsonEncode({'message': 'network down'}))),
    'application/json',
  );
}

/// 内存版小说离线区：只覆盖详情/阅读用到的读接口。
class _MemoryBookStore extends OfflineBookStore {
  _MemoryBookStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final Map<String, OfflineBook> books = <String, OfflineBook>{};
  final Map<String, Map<String, ChapterContent>> chapters =
      <String, Map<String, ChapterContent>>{};

  /// 写入一本 3 章的整本缓存（默认 3/3 已缓存）。
  void seedOfflineBook({
    String bookId = '1',
    String title = '离线剑来',
    int completed = 3,
    int total = 3,
  }) {
    books[bookId] = OfflineBook(
      bookId: bookId,
      title: title,
      cover: '',
      chapters: [
        for (var i = 0; i < total; i++)
          OfflineChapter(
            id: 'c$i',
            title: '离线第${i + 1}章',
            volumeName: '',
            index: i,
          ),
      ],
      completed: completed,
    );
    chapters[bookId] = {
      for (var i = 0; i < completed; i++)
        'c$i': ChapterContent(
          id: 'c$i',
          title: '离线第${i + 1}章',
          paragraphs: ['离线正文 c$i'],
        ),
    };
  }

  @override
  Future<OfflineBook?> read(String bookId) async => books[bookId];

  @override
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async =>
      chapters[bookId]?[chapterId];

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() async => OfflineStats(
    count: books.length,
    bytes: 0,
    capBytes: OfflineBookStore.novelCapBytes,
  );
}

/// 内存版短剧离线区：详情页的下载器恢复只要求它不碰真实磁盘。
class _MemorySeriesStore extends OfflineSeriesStore {
  _MemorySeriesStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  @override
  Future<OfflineSeries?> read(String seriesId) async => null;

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() async => const OfflineStats(
    count: 0,
    bytes: 0,
    capBytes: OfflineSeriesStore.videoCapBytes,
  );
}

/// 固定的任务表：模拟「上次任务暂停，重启后展示进度」。
class _FixedTaskStore extends OfflineTaskStore {
  _FixedTaskStore(this.task);

  final OfflineTask? task;

  @override
  Future<OfflineTask?> read() async => task;

  @override
  Future<void> write(OfflineTask value) async {}

  @override
  Future<void> clear() async {}
}
