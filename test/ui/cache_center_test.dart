import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/cache/cache_center_page.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_queue.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 缓存中心页：分区、实时进度/网速、暂停/失败态、空态与 Hero 进详情。
///
/// 活动任务通过 `offlineTaskProvider.overrideWithValue` 注入——页面只读这个
/// 只读快照，不要在测试里继承 final 的 OfflineDownloader。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  OfflineBookSummary book({
    String id = 'b1',
    String title = '剑来',
    String cover = '',
    int completed = 3,
    int total = 10,
    int bytes = 48 * 1024,
  }) => OfflineBookSummary(
    bookId: id,
    title: title,
    cover: cover,
    completed: completed,
    total: total,
    bytes: bytes,
    updatedAt: DateTime.now(),
  );

  OfflineSeriesSummary drama({
    String id = 's1',
    String title = '十八岁太奶奶驾到',
    String cover = '',
    int completed = 2,
    int total = 8,
    int bytes = 300 * 1024 * 1024,
  }) => OfflineSeriesSummary(
    seriesId: id,
    title: title,
    cover: cover,
    completed: completed,
    total: total,
    bytes: bytes,
    updatedAt: DateTime.now(),
  );

  OfflineTask task({
    OfflineTaskKind kind = OfflineTaskKind.novel,
    String id = 'b2',
    String title = '雪中悍刀行',
    String cover = '',
    int completed = 44,
    int total = 120,
    int bytes = 152 * 1024 * 1024,
    int speed = 0,
    OfflineTaskStatus status = OfflineTaskStatus.running,
    String? error,
  }) => OfflineTask(
    kind: kind,
    id: id,
    title: title,
    cover: cover,
    completed: completed,
    total: total,
    bytes: bytes,
    speedBytesPerSecond: speed,
    status: status,
    error: error,
  );

  /// 页面专属的 provider 覆写。活动任务用 `offlineTaskProvider` 注入：页面
  /// 只读这个快照，不继承 final 的 OfflineDownloader。
  List<Override> overrides({
    List<OfflineBookSummary> books = const [],
    List<OfflineSeriesSummary> series = const [],
    OfflineTask? active,
  }) => [
    offlineNovelListProvider.overrideWith((ref) async => books),
    offlineVideoListProvider.overrideWith((ref) async => series),
    offlineTaskProvider.overrideWithValue(active),
  ];

  /// 本页自己 pump：pumpPreview 已固定覆写了两个 list provider，再添加会
  /// 触发 Riverpod「同一 container 不允许重复 override」，所以这里按同样的
  /// 预览壳（字体/主题/390×844）另起一份只属于本页的覆写列表。
  Future<void> pumpCenter(
    WidgetTester tester, {
    required List<Override> extra,
    FakePreviewTransport? transport,
    OfflineBookStore? bookStore,
    OfflineSeriesStore? seriesStore,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(
            ApiClient(transport ?? FakePreviewTransport()),
          ),
          readerChapterCacheProvider.overrideWithValue(PreviewChapterCache()),
          // 默认就用记录型 store：它不碰真实磁盘，也不会在页面进入时的自愈
          // 逻辑里打出「预览缓存不应访问磁盘」的噪音日志。
          offlineBookStoreProvider.overrideWithValue(
            bookStore ?? _RecordingBookStore(),
          ),
          offlineSeriesStoreProvider.overrideWithValue(
            seriesStore ?? _RecordingSeriesStore(),
          ),
          ...extra,
        ],
        child: const PreviewApp(home: CacheCenterPage()),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  /// 页面 pump 完后用真实 queue notifier 入队，走一遍「排队条目出现→取消排队」
  /// 的真实状态链路（UI 只依赖 offlineQueueProvider，不存本地状态）。
  Future<void> enqueueNovel(
    WidgetTester tester, {
    String id = 'b3',
    String title = '排队之书',
  }) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CacheCenterPage)),
    );
    container
        .read(offlineQueueProvider.notifier)
        .enqueue(
          OfflineQueueJob(
            kind: OfflineTaskKind.novel,
            id: id,
            title: title,
            cover: '',
            items: const [],
          ),
        );
    await tester.pumpAndSettle();
  }

  testWidgets('分区展示：运行中任务补到小说分区最前，带百分比/网速/体积', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        books: [book(completed: 10)],
        series: [drama(completed: 8)],
        active: task(speed: 1258291),
      ),
    );

    expect(find.text('小说'), findsOneWidget);
    expect(find.text('短剧'), findsOneWidget);
    // 运行中任务（不在已下载列表里）补到分区最前。
    expect(find.text('雪中悍刀行'), findsOneWidget);
    expect(
      find.text('下载中 37% · 1.2 MB/s · 152 MB'),
      findsOneWidget,
      reason: '44/120 ≈ 37%，网速 >0 才显示',
    );
    // 已下载条目照常展示。
    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('已缓存 10/10 章 · 48 KB'), findsOneWidget);
    expect(find.text('十八岁太奶奶驾到'), findsOneWidget);
    expect(find.text('已缓存 8/8 集 · 300 MB'), findsOneWidget);
    // 三条记录各有一条进度条；运行中有暂停按钮，已完成没有动作按钮。
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    expect(find.byIcon(Icons.pause_circle_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outlined), findsNothing);
    expect(
      tester.getTopLeft(find.text('雪中悍刀行')).dy,
      lessThan(tester.getTopLeft(find.text('剑来')).dy),
      reason: '活动任务应补在小说分区最前',
    );
  });

  testWidgets('任务命中已下载条目时，用任务的实时进度覆盖 manifest 快照', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        books: [book()],
        active: task(id: 'b1', title: '剑来'),
      ),
    );

    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('下载中 37% · 152 MB'), findsOneWidget);
    expect(
      find.text('已缓存 3/10 章 · 48 KB'),
      findsNothing,
      reason: '有活动任务时应显示任务进度，而不是旧 manifest 快照',
    );
  });

  testWidgets('暂停态：已暂停文案 + 继续按钮 + 暂停原因', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        active: task(status: OfflineTaskStatus.paused, error: '应用重启，任务已暂停'),
      ),
    );

    expect(find.text('已暂停 37% · 152 MB'), findsOneWidget);
    expect(find.text('应用重启，任务已暂停'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outlined), findsOneWidget);
  });

  testWidgets('失败态：下载失败原因 + 重试按钮', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        active: task(
          status: OfflineTaskStatus.failed,
          error: '网络异常',
          completed: 10,
          bytes: 20 * 1024 * 1024,
        ),
      ),
    );

    expect(find.text('下载失败 · 网络异常'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('两个分区都空时显示空态', (tester) async {
    await pumpCenter(tester, extra: overrides());

    expect(find.textContaining('还没有下载内容'), findsOneWidget);
    expect(find.textContaining('在详情页点「缓存」即可整本/整剧下载'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  testWidgets('点小说条目：Hero 飞入小说详情页', (tester) async {
    final withCover = book(cover: 'https://example.com/cache-cover.jpg');
    await pumpCenter(tester, extra: overrides(books: [withCover]));

    await tester.tap(find.text('剑来'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(DetailPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cover-hero-flight')),
      findsOneWidget,
      reason: '进详情时封面应在飞行',
    );

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(DetailPage), findsOneWidget);
    expect(find.text('剑来'), findsWidgets);
  });

  testWidgets('点短剧条目：Hero 飞入短剧详情页', (tester) async {
    final withCover = drama(cover: 'https://example.com/cache-drama.jpg');
    await pumpCenter(tester, extra: overrides(series: [withCover]));

    await tester.tap(find.text('十八岁太奶奶驾到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cover-hero-flight')),
      findsOneWidget,
      reason: '短剧封面同样要 Hero 飞入',
    );

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoDetailPage), findsOneWidget);
  });

  testWidgets('排队中条目：显示排队状态行与取消排队按钮，取消后消失', (tester) async {
    await pumpCenter(tester, extra: overrides(books: [book()]));
    await enqueueNovel(tester);

    expect(find.text('排队之书'), findsOneWidget);
    expect(find.text('排队中 · 等前面的任务完成后自动开始'), findsOneWidget);
    expect(find.byTooltip('取消排队'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('排队之书'), findsNothing);
    expect(find.text('排队中 · 等前面的任务完成后自动开始'), findsNothing);
    // 已下载条目不受影响。
    expect(find.text('剑来'), findsOneWidget);
  });

  testWidgets('排队条目与已下载 summary 同 id：合并展示已有进度且不重复', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        books: [book(id: 'b3', title: '排队之书', completed: 3, total: 10)],
      ),
    );
    expect(find.text('已缓存 3/10 章 · 48 KB'), findsOneWidget);

    await enqueueNovel(tester);
    expect(find.text('排队之书'), findsOneWidget, reason: '同一 id 只能有一条');
    expect(find.text('排队中 · 已缓存 3/10 章 · 等前面的任务完成后自动开始'), findsOneWidget);
    // 排队条目用已有 manifest 的进度条。
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('删除入口：取消不删，确认后 clearFor 删除并弹 SnackBar', (tester) async {
    final bookStore = _RecordingBookStore();
    await pumpCenter(
      tester,
      extra: overrides(books: [book()]),
      bookStore: bookStore,
    );
    expect(find.byTooltip('删除缓存'), findsOneWidget);

    await tester.tap(find.byTooltip('删除缓存'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsOneWidget);
    expect(find.textContaining('已缓存 3/10 章'), findsWidgets);
    expect(find.textContaining('（48 KB）'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsNothing);
    expect(bookStore.deleted, isEmpty, reason: '取消不应删除');

    await tester.tap(find.byTooltip('删除缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(bookStore.deleted, ['b1']);
    expect(find.text('已删除《剑来》的离线缓存'), findsOneWidget);
  });

  testWidgets('删除运行中的任务：对话框说明会先停止当前任务', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        active: task(id: 'b2', title: '雪中悍刀行'),
      ),
      bookStore: _RecordingBookStore(),
    );
    await tester.tap(find.byTooltip('删除缓存'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsOneWidget);
    expect(find.textContaining('会先停止当前任务'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('清空菜单：分区为空时置灰，取消不调用 clearAll', (tester) async {
    final bookStore = _RecordingBookStore();
    final seriesStore = _RecordingSeriesStore();
    await pumpCenter(
      tester,
      extra: overrides(books: [book()]),
      bookStore: bookStore,
      seriesStore: seriesStore,
    );

    await tester.tap(find.byTooltip('清空缓存'));
    await tester.pumpAndSettle();
    expect(find.text('清空小说缓存'), findsOneWidget);
    expect(find.text('清空短剧缓存'), findsOneWidget);
    final menuItems = tester
        .widgetList<PopupMenuItem<OfflineTaskKind>>(
          find.byType(PopupMenuItem<OfflineTaskKind>),
        )
        .toList();
    expect(menuItems, hasLength(2));
    expect(menuItems[0].enabled, isTrue, reason: '小说分区有内容');
    expect(menuItems[1].enabled, isFalse, reason: '短剧分区为空应置灰');

    await tester.tap(find.text('清空小说缓存'));
    await tester.pumpAndSettle();
    expect(find.text('清空小说离线缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(bookStore.clearAllCalls, 0);
    expect(seriesStore.clearAllCalls, 0);
  });

  testWidgets('清空确认：clearAll 只清本区、撤掉同区排队项并弹 SnackBar', (tester) async {
    final bookStore = _RecordingBookStore();
    final seriesStore = _RecordingSeriesStore();
    await pumpCenter(
      tester,
      extra: overrides(books: [book()], series: [drama()]),
      bookStore: bookStore,
      seriesStore: seriesStore,
    );
    // 预先排一个小说等待项，清空时应该一起被撤掉。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CacheCenterPage)),
    );
    container
        .read(offlineQueueProvider.notifier)
        .enqueue(
          OfflineQueueJob(
            kind: OfflineTaskKind.novel,
            id: 'b9',
            title: '排队待清空',
            cover: '',
            items: const [],
          ),
        );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('清空缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空小说缓存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 本'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(bookStore.clearAllCalls, 1);
    expect(seriesStore.clearAllCalls, 0, reason: '短剧区不受影响');
    expect(container.read(offlineQueueProvider), isEmpty);
    expect(find.text('已清空离线小说缓存'), findsOneWidget);
  });

  testWidgets('删除确认对话框', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(books: [book()]),
      bookStore: _RecordingBookStore(),
    );
    await tester.tap(find.byTooltip('删除缓存'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/cache_center_delete_dialog.png'),
    );
  });

  testWidgets('缓存中心页', (tester) async {
    await pumpCenter(
      tester,
      extra: overrides(
        books: [book(completed: 10, bytes: 800 * 1024)],
        series: [drama(completed: 8)],
        active: task(speed: 1258291),
      ),
    );
    await enqueueNovel(tester, id: 'b3', title: '排队测试书');
    await expectLater(
      find.byType(CacheCenterPage),
      matchesGoldenFile('../goldens/cache_center.png'),
    );
  });
}

/// 记录型小说离线区：删除/清空只记调用，不碰真实磁盘。
class _RecordingBookStore extends OfflineBookStore {
  _RecordingBookStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final List<String> deleted = <String>[];
  int clearAllCalls = 0;

  @override
  Future<void> delete(String bookId) async => deleted.add(bookId);

  @override
  Future<void> clearAll() async => clearAllCalls += 1;

  @override
  Future<List<OfflineBookSummary>> summaries() async =>
      const <OfflineBookSummary>[];

  @override
  Future<void> reconcile(String bookId) async {}

  @override
  Future<int> pruneOrphans() async => 0;

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineBook?> read(String bookId) async => null;

  @override
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async =>
      null;

  @override
  Future<OfflineStats> stats() async => const OfflineStats(
    count: 0,
    bytes: 0,
    capBytes: OfflineBookStore.novelCapBytes,
  );
}

/// 记录型短剧离线区：用途同上。
class _RecordingSeriesStore extends OfflineSeriesStore {
  _RecordingSeriesStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final List<String> deleted = <String>[];
  int clearAllCalls = 0;

  @override
  Future<void> delete(String seriesId) async => deleted.add(seriesId);

  @override
  Future<void> clearAll() async => clearAllCalls += 1;

  @override
  Future<List<OfflineSeriesSummary>> summaries() async =>
      const <OfflineSeriesSummary>[];

  @override
  Future<void> reconcile(String seriesId) async {}

  @override
  Future<int> pruneOrphans() async => 0;

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineSeries?> read(String seriesId) async => null;

  @override
  Future<OfflineStats> stats() async => const OfflineStats(
    count: 0,
    bytes: 0,
    capBytes: OfflineSeriesStore.videoCapBytes,
  );
}
