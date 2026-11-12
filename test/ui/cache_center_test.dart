import 'dart:io';

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
/// 真实文件的离线自愈在 widget test 里要交替 `runAsync`（让 dart:io 完成）与
/// `pump`（冲掉测试 zone 的 microtask），否则一段 runAsync 只够走完一次 IO
/// await，自愈链走不到 reconcile 的收尾。
Future<void> _settleOfflineSelfHeal(WidgetTester tester) async {
  // 自愈链里每一段 `await` 是一次真实 IO：每轮 runAsync 让一次 IO 完成，
  // 随后的 pump 冲掉 fake zone 里的 microtask 让链走到下一个 await。
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  late Directory tempRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('cache_center_test_');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
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

  group('进页扫盘自愈守卫（P1-1：不误删下载中的 .part）', () {
    OfflineQueuedTask queued(OfflineTaskKind kind) => OfflineQueuedTask(
      kind: kind,
      id: 'queued-${kind.wireName}',
      title: '排队中的任务',
      cover: '',
    );

    test('busyOfflineKinds：只有 done 不繁忙，排队项按 kind 计入', () {
      for (final status in OfflineTaskStatus.values) {
        final busy = busyOfflineKinds(
          task(kind: OfflineTaskKind.novel, status: status),
          const <OfflineQueuedTask>[],
        );
        expect(
          busy.contains(OfflineTaskKind.novel),
          status != OfflineTaskStatus.done,
          reason: '$status 状态的区是否算繁忙',
        );
        expect(
          busy.contains(OfflineTaskKind.video),
          isFalse,
          reason: '任务只占一个区，不能把另一个区也标成繁忙',
        );
      }
      // 没有活动任务、只有排队项时，该区同样随时可能开始写盘。
      expect(busyOfflineKinds(null, [queued(OfflineTaskKind.video)]), {
        OfflineTaskKind.video,
      });
      expect(busyOfflineKinds(null, const <OfflineQueuedTask>[]), isEmpty);
    });

    testWidgets('运行中打开缓存中心：真 store 不删正在下载的 .part', (tester) async {
      final paths = OfflinePaths(rootDirectory: () async => tempRoot);
      final seriesStore = OfflineSeriesStore(paths: paths);
      late File part;
      await tester.runAsync(() async {
        await seriesStore.begin(
          OfflineSeries(
            seriesId: 's1',
            title: '下载中的剧',
            episodes: const [
              OfflineEpisode(id: 'e0', title: '第一集', index: 0),
              OfflineEpisode(id: 'e1', title: '第二集', index: 1),
            ],
          ),
        );
        part = await seriesStore.partFile('s1', 'e0');
        await part.writeAsBytes(List<int>.filled(2048, 7));
      });

      await pumpCenter(
        tester,
        extra: overrides(
          series: [drama(id: 's1')],
          // 缓存中心正是「缓存中」按钮的落地页：任务正在下载这一部剧。
          active: task(kind: OfflineTaskKind.video, id: 's1'),
        ),
        seriesStore: seriesStore,
      );
      // 让 postFrame 的自愈真实跑完；守卫失效时这里会删掉 .part，断言就会红。
      await _settleOfflineSelfHeal(tester);

      final partExists = await tester.runAsync(part.exists);
      expect(
        partExists,
        isTrue,
        reason: 'reconcile/pruneOrphans 删掉 .part 会让当前集从 0 重下（P1-1）',
      );
    });

    testWidgets('暂停待续同样跳过：繁忙区一次扫盘都不发，另一区照常校正', (tester) async {
      final bookStore = _RecordingBookStore(summariesValue: [book()]);
      final seriesStore = _RecordingSeriesStore(
        summariesValue: [drama(id: 's1')],
      );
      await pumpCenter(
        tester,
        extra: overrides(
          books: [book()],
          series: [drama(id: 's1')],
          // paused/failed 随时会被「继续 / 重试」重新启动，同样算繁忙。
          active: task(
            kind: OfflineTaskKind.video,
            id: 's1',
            status: OfflineTaskStatus.paused,
          ),
        ),
        bookStore: bookStore,
        seriesStore: seriesStore,
      );

      expect(bookStore.reconcileCalls, 1, reason: '空闲的小说区照常校正');
      expect(bookStore.pruneOrphansCalls, 1);
      expect(seriesStore.reconcileCalls, 0, reason: '待续的短剧区不扫盘');
      expect(seriesStore.pruneOrphansCalls, 0);
      // 整区 cleanupPartFiles 只留给启动恢复（`_restore()`）与删除单条路径，
      // 缓存中心进页不再调用——两区都应 0 次。
      expect(
        seriesStore.cleanupPartFilesCalls,
        0,
        reason: '缓存中心不再整区清 .part（只留启动恢复/删除单条路径）',
      );
      expect(bookStore.cleanupPartFilesCalls, 0);
    });

    testWidgets('空闲时打开缓存中心：照常校正 manifest，但不清理 .part', (tester) async {
      final paths = OfflinePaths(rootDirectory: () async => tempRoot);
      final seriesStore = OfflineSeriesStore(paths: paths);
      late File part;
      await tester.runAsync(() async {
        await seriesStore.begin(
          OfflineSeries(
            seriesId: 's1',
            title: '空闲的剧',
            episodes: const [
              OfflineEpisode(id: 'e0', title: '第一集', index: 0),
              OfflineEpisode(id: 'e1', title: '第二集', index: 1),
            ],
          ),
        );
        // e0 已正式落盘、e1 半截（模拟上次崩溃留下的 .part）。
        final episode = await seriesStore.episodeFilePath('s1', 'e0');
        await episode.writeAsBytes(List<int>.filled(10, 1));
        part = await seriesStore.partFile('s1', 'e1');
        await part.writeAsBytes(List<int>.filled(10, 2));
      });

      await pumpCenter(
        tester,
        extra: overrides(series: [drama(id: 's1', completed: 0, total: 2)]),
        seriesStore: seriesStore,
      );
      // 让 postFrame 的自愈真实跑完；守卫失效时这里会删掉 .part，断言就会红。
      await _settleOfflineSelfHeal(tester);

      final snapshot = await tester.runAsync(() async {
        return (await seriesStore.read('s1'), await part.exists());
      });
      final loaded = snapshot?.$1;
      final partExists = snapshot?.$2;
      expect(loaded!.completed, 1, reason: '空闲区按文件存在校正 manifest');
      expect(partExists, isTrue, reason: '.part 只由启动恢复与删除单条清理，进页扫盘不碰它');
    });
  });
}

/// 记录型小说离线区：删除/清空只记调用，不碰真实磁盘；扫盘自愈的调用也
/// 计数（P1-1 守卫用例要能观察到「该区一次都没被扫」）。
class _RecordingBookStore extends OfflineBookStore {
  _RecordingBookStore({this.summariesValue = const <OfflineBookSummary>[]})
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final List<OfflineBookSummary> summariesValue;
  final List<String> deleted = <String>[];
  final List<String> reconciled = <String>[];
  int clearAllCalls = 0;
  int pruneOrphansCalls = 0;
  int cleanupPartFilesCalls = 0;

  int get reconcileCalls => reconciled.length;

  @override
  Future<void> delete(String bookId) async => deleted.add(bookId);

  @override
  Future<void> clearAll() async => clearAllCalls += 1;

  @override
  Future<List<OfflineBookSummary>> summaries() async => summariesValue;

  @override
  Future<void> reconcile(String bookId) async => reconciled.add(bookId);

  @override
  Future<int> pruneOrphans({bool cleanupParts = true}) async {
    pruneOrphansCalls += 1;
    return 0;
  }

  @override
  Future<void> cleanupPartFiles() async => cleanupPartFilesCalls += 1;

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
  _RecordingSeriesStore({this.summariesValue = const <OfflineSeriesSummary>[]})
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final List<OfflineSeriesSummary> summariesValue;
  final List<String> deleted = <String>[];
  final List<String> reconciled = <String>[];
  int clearAllCalls = 0;
  int pruneOrphansCalls = 0;
  int cleanupPartFilesCalls = 0;

  int get reconcileCalls => reconciled.length;

  @override
  Future<void> delete(String seriesId) async => deleted.add(seriesId);

  @override
  Future<void> clearAll() async => clearAllCalls += 1;

  @override
  Future<List<OfflineSeriesSummary>> summaries() async => summariesValue;

  @override
  Future<void> reconcile(String seriesId, {bool cleanupParts = true}) async =>
      reconciled.add(seriesId);

  @override
  Future<int> pruneOrphans({bool cleanupParts = true}) async {
    pruneOrphansCalls += 1;
    return 0;
  }

  @override
  Future<void> cleanupPartFiles() async => cleanupPartFilesCalls += 1;

  @override
  Future<OfflineSeries?> read(String seriesId) async => null;

  @override
  Future<OfflineStats> stats() async => const OfflineStats(
    count: 0,
    bytes: 0,
    capBytes: OfflineSeriesStore.videoCapBytes,
  );
}
