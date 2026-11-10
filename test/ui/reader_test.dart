import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/features/cache/cache_center_page.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_downloader.dart';
import 'package:novel_playlet/features/cache/offline_queue.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_bubble.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:novel_playlet/features/reader/reader_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 阅读页预览：分页、工具栏、切章过渡与设置弹层主题作用域。
///
/// 更新基线：`flutter test --update-goldens test/ui/reader_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('阅读页', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('../goldens/reader.png'),
    );
  });

  testWidgets('阅读页-工具栏', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    // 点中间 1/3 呼出工具栏。
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('评论'), findsOneWidget, reason: '工具栏应提供本章评论入口');
    // 顶部只剩返回 + 两个状态文本动作（书名/章节名已移除）。
    expect(find.text('加入书架'), findsOneWidget);
    expect(find.text('缓存小说'), findsOneWidget);
    expect(find.text('剑来'), findsNothing, reason: '顶部不再显示书名');
    // 底部：上一章/下一章换成日间/夜间切换。
    expect(find.text('上一章'), findsNothing);
    expect(find.text('下一章'), findsNothing);
    expect(find.text('夜间'), findsOneWidget);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('../goldens/reader_toolbar.png'),
    );
  });

  testWidgets('阅读页-加入书架后变只读状态，点已在书架不会移出', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('加入书架'), findsOneWidget);

    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('加入书架'), findsNothing);
    expect(find.text('已在书架'), findsOneWidget);
    expect(
      await container.read(readingStoreProvider).isOnShelf('1'),
      isTrue,
      reason: '点加入书架应真的写进书架',
    );

    // 已在书架是只读状态：点击不响应、更不能把书移出书架。
    await tester.tap(find.text('已在书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('已在书架'), findsOneWidget);
    expect(
      await container.read(readingStoreProvider).isOnShelf('1'),
      isTrue,
      reason: '点已在书架不应移除书架',
    );
  });

  testWidgets('阅读页-日间/夜间切换回到上次选择的浅色纸', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    final settingsController = container.read(readerSettingsProvider.notifier);
    // 先选一个浅色纸（设置弹层里的「护眼」）。
    settingsController.setPaper(ReaderPaper.green);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('夜间'), findsOneWidget);

    await tester.tap(find.text('夜间'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(container.read(readerSettingsProvider).paper, ReaderPaper.night);
    expect(find.text('日间'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(
      scaffold.backgroundColor,
      ReaderPaper.night.background,
      reason: '夜间底色应为黑色纸',
    );
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('../goldens/reader_toolbar_night.png'),
    );

    // 切回日间＝回到上次选的浅色纸，不是默认纸。
    await tester.tap(find.text('日间'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(container.read(readerSettingsProvider).paper, ReaderPaper.green);
    expect(find.text('夜间'), findsOneWidget);
  });

  testWidgets('阅读页-夜间偏好恢复后日间回到落盘的浅色纸', (tester) async {
    // 上次退出时是夜间、日间记忆是护眼：重进阅读页点「日间」应回护眼，
    // 不能回默认纸色（偏好落盘 reader_day_paper_v1）。
    SharedPreferences.setMockInitialValues({
      'reader_paper_v1': 'night',
      'reader_day_paper_v1': 'green',
    });
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    await container.read(readerSettingsProvider.notifier).restoreFuture;
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(container.read(readerSettingsProvider).paper, ReaderPaper.night);

    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('日间'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(container.read(readerSettingsProvider).paper, ReaderPaper.green);
  });

  testWidgets('阅读页-缓存状态：未缓存显示缓存小说', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('缓存小说'), findsOneWidget);
    expect(find.text('已缓存'), findsNothing);
  });

  testWidgets('阅读页-缓存状态：整本下载完显示已缓存', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      extraOverrides: [
        offlineNovelProvider.overrideWith((ref, bookId) async {
          return OfflineBook(
            bookId: bookId,
            title: '剑来',
            chapters: const [OfflineChapter(id: 'c1', title: '第一章', index: 0)],
            completed: 1,
          );
        }),
      ],
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('已缓存'), findsOneWidget);
    expect(find.text('缓存小说'), findsNothing);
  });

  testWidgets('阅读页-缓存状态：已排队显示缓存中', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    container
        .read(offlineQueueProvider.notifier)
        .enqueue(
          const OfflineQueueJob(
            kind: OfflineTaskKind.novel,
            id: '1',
            title: '剑来',
            cover: '',
            items: <Chapter>[],
          ),
        );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('缓存中'), findsOneWidget);
    expect(find.text('缓存小说'), findsNothing);
  });

  testWidgets('阅读页-点缓存小说开始整本缓存，文案变缓存中', (tester) async {
    final bookStore = _DownloadingBookStore();
    final network = _GatedOfflineNetwork();
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      offlineBookStore: bookStore,
      extraOverrides: [
        offlineNetworkProvider.overrideWithValue(network),
        // 下载器节奏全置 0：用例只关心「点下去后进入下载中」，不等待真实间隔。
        offlineDownloadSettingsProvider.overrideWithValue(
          const OfflineDownloadSettings(
            batchGap: Duration.zero,
            retryDelay: Duration.zero,
            progressInterval: Duration.zero,
            manifestInterval: Duration.zero,
          ),
        ),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('缓存小说'), findsOneWidget);

    await tester.tap(find.text('缓存小说'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      container.read(offlineDownloaderProvider)?.id,
      '1',
      reason: '点缓存小说应真的启动整本下载',
    );
    expect(find.text('缓存中'), findsOneWidget);
    expect(find.text('缓存小说'), findsNothing);
  });

  testWidgets('阅读页-顶部状态：已在书架只读、已缓存点击进缓存中心', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      extraOverrides: [
        offlineNovelProvider.overrideWith((ref, bookId) async {
          return OfflineBook(
            bookId: bookId,
            title: '剑来',
            chapters: const [OfflineChapter(id: 'c1', title: '第一章', index: 0)],
            completed: 1,
          );
        }),
      ],
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('已在书架'), findsOneWidget);
    expect(find.text('已缓存'), findsOneWidget);
    // 「已在书架」是只读态：不渲染任何手势控件，点击也不会触发动作。
    expect(
      find.ancestor(of: find.text('已在书架'), matching: find.byType(TextButton)),
      findsNothing,
    );
    // 「已缓存」是按钮：点了进缓存中心（看已下载内容/删除）。
    expect(
      find.ancestor(of: find.text('已缓存'), matching: find.byType(TextButton)),
      findsOneWidget,
    );
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('../goldens/reader_toolbar_readonly.png'),
    );

    await tester.tap(find.text('已缓存'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(CacheCenterPage), findsOneWidget);
  });

  testWidgets('阅读页-缓存中点进缓存中心（暂停/失败后能继续）', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    // 模拟「暂停 / 取消后 manifest 只完成一部分」：没有活动任务但也不是
    // 可从头开始的状态，阅读页不能让它成为点不动的死状态。
    container
        .read(offlineQueueProvider.notifier)
        .enqueue(
          const OfflineQueueJob(
            kind: OfflineTaskKind.novel,
            id: '1',
            title: '剑来',
            cover: '',
            items: <Chapter>[],
          ),
        );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('缓存中'), findsOneWidget);

    await tester.tap(find.text('缓存中'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(CacheCenterPage), findsOneWidget);
  });

  testWidgets('阅读页-工具栏收起后必须完全移出屏幕', (tester) async {
    // 带刘海/Home 指示条的真机尺寸：工具栏如果在 SafeArea 里，收起时只会
    // 停在状态栏那条里（真机复现过），这里把它钉死。
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(
            ApiClient(FakePreviewTransport()),
          ),
          readerChapterCacheProvider.overrideWithValue(PreviewChapterCache()),
          // 离线区同样不碰真实磁盘（path_provider 在 widget test 下没有平台实现，
          // 真实 IO 的 Future 不会完成，会让阅读页 bootstrap 挂住）。
          ...previewOfflineOverrides(),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReaderPage(
            args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // 默认收起：顶部栏底边必须 <= 0，底部栏顶边必须 >= 屏幕高度。
    final topRect = tester.getRect(find.byType(ReaderTopBar));
    final bottomRect = tester.getRect(find.byType(ReaderBottomBar));
    expect(
      topRect.bottom,
      lessThanOrEqualTo(0.5),
      reason: '收起后顶部栏仍露出 ${topRect.bottom}pt',
    );
    expect(
      bottomRect.top,
      greaterThanOrEqualTo(873.5),
      reason: '收起后底部栏仍露出 ${874 - bottomRect.top}pt',
    );
  });

  testWidgets('阅读页-工具栏打开时左右滑动不翻页，压暗遮罩保留', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    final indicatorBefore = _pageIndicator(tester);
    expect(indicatorBefore, isNotEmpty, reason: '底部信息条应显示页码');

    // 点中间 1/3 呼出工具栏。
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // 工具栏打开时横向拖 PageView：手势要留给「收工具栏/点按钮」，不能翻页。
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(_pageIndicator(tester), indicatorBefore, reason: '工具栏打开时左右滑动不应翻页');

    // 压暗遮罩保留：视觉上压暗正文，但不接收点击（IgnorePointer），
    // 不抢手势，也不影响上面的「不翻页」。
    final scrim = find.byWidgetPredicate(
      (widget) =>
          widget is ColoredBox && widget.color == const Color(0x33000000),
    );
    expect(scrim, findsOneWidget, reason: '工具栏打开时应保留压暗正文的遮罩层');
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrim, matching: find.byType(AnimatedOpacity)).first,
    );
    expect(opacity.opacity, 1.0, reason: '工具栏打开时遮罩应为可见状态');
    expect(
      find.ancestor(of: scrim, matching: find.byType(IgnorePointer)),
      findsWidgets,
      reason: '遮罩不能抢手势，点击要穿透到正文',
    );
  });

  testWidgets('阅读页-入口带 blockIndex 时恢复到对应页', (tester) async {
    // 假数据每章 18 段，第 9 段一定不在第 1 页。
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(
          bookId: '1',
          bookTitle: '剑来',
          chapterId: 'c1',
          chapterIndex: 0,
          blockIndex: 9,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final label = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .firstWhere(
          (data) => RegExp(r'^\d+/\d+$').hasMatch(data),
          orElse: () => '',
        );
    expect(label, isNotEmpty, reason: '底部信息条应显示页码');
    final currentPage = int.parse(label.split('/').first);
    expect(currentPage, greaterThan(1), reason: '带 blockIndex 进入不应落在第 1 页');
  });

  testWidgets('阅读页-切章有过渡且底栏章节名更新', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    // 底栏初始显示第 1 章。
    expect(find.textContaining('第一章'), findsWidgets);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    final args = const ReaderArgs(bookId: '1', bookTitle: '剑来');
    await container.read(readerSessionProvider(args).notifier).nextChapter();

    // 过渡中点：正文应该处于"未完成"状态（opacity < 1 或存在横向位移）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final transitions = tester
        .widgetList<FractionalTranslation>(find.byType(FractionalTranslation))
        .where((widget) => widget.translation.dx != 0)
        .toList();
    expect(transitions, isNotEmpty, reason: '切章应有一段横向过渡动画');

    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('第二章'), findsWidgets);
  });

  /// 阅读弹层的主题作用域回归：弹层挂在 root Navigator 上，必须显式包一层
  /// 「纸色对应的 Theme」。否则暗色 App + 浅色纸底时，弹层里会用全局的亮色
  /// primary 画文字，在纸色上对比度只有 1.5:1（曾出现目录当前章看不清）。
  testWidgets('阅读页-设置弹层（暗色 App + 纸色底）', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      brightness: Brightness.dark,
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final sheetContext = tester.element(find.byType(ReaderSettingsSheet));
    expect(
      Theme.of(sheetContext).colorScheme.brightness,
      Brightness.light,
      reason: '默认纸色是浅色，弹层应该用纸色的浅色 scheme，而不是全局暗色',
    );
    await expectLater(
      find.byType(ReaderSettingsSheet),
      matchesGoldenFile('../goldens/reader_settings_sheet.png'),
    );
  });

  testWidgets('阅读页-切章失败保留旧正文，错误降级为可重试提示条', (tester) async {
    final transport = FakePreviewTransport();
    transport.failingChapterIds.add('c2');
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      transport: transport,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    const args = ReaderArgs(bookId: '1', bookTitle: '剑来');
    // 进入下一章（c2）失败：不能把正在读的正文清掉。
    await container.read(readerSessionProvider(args).notifier).nextChapter();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.byType(ReaderPageContent), findsWidgets, reason: '旧正文应保留');
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('加载失败'), findsOneWidget);

    // 网络恢复后点重试：重试的是失败的那一章，提示条消失、正文换成新章。
    transport.failingChapterIds.remove('c2');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('重试'), findsNothing);
    expect(find.textContaining('加载失败'), findsNothing);
    expect(find.textContaining('第二章'), findsWidgets);
  });

  testWidgets('阅读页-段评气泡随开关显示/隐藏，点气泡打开评论面板', (tester) async {
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    expect(
      find.byType(ReaderParagraphBubble),
      findsWidgets,
      reason: '预览章有段评计数，首屏应该画出气泡',
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    container.read(readerSettingsProvider.notifier).setShowBubbles(false);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(ReaderParagraphBubble), findsNothing);

    container.read(readerSettingsProvider.notifier).setShowBubbles(true);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(ReaderParagraphBubble), findsWidgets);

    // 点第一个气泡：打开该段的评论面板（预览 transport 返回两条段评）。
    await tester.tap(find.byType(ReaderParagraphBubble).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.textContaining('条评论'), findsOneWidget);
    expect(find.text('预览段评 1'), findsOneWidget);
  });

  testWidgets('阅读页-关闭段评气泡后不预取评论，点评论入口才请求', (tester) async {
    SharedPreferences.setMockInitialValues({'reader_show_bubbles_v1': false});
    final transport = FakePreviewTransport();
    await pumpPreview(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      transport: transport,
    );
    expect(
      transport.calls.where((call) => call.contains('/reviews')),
      isEmpty,
      reason: '关闭气泡后不应为了计数预取段评',
    );
    expect(find.byType(ReaderParagraphBubble), findsNothing);

    // 打开工具栏 → 点「评论」：这是唯一一次按需请求 idea 列表。
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      transport.calls.where(
        (call) => call.contains('/chapters/') && call.contains('/reviews'),
      ),
      isNotEmpty,
    );
    expect(find.textContaining('条评论'), findsOneWidget);
  });
}

/// 底部常驻信息条里的页码文案（`n/m`）。
String _pageIndicator(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? '')
      .firstWhere(
        (data) => RegExp(r'^\d+/\d+$').hasMatch(data),
        orElse: () => '',
      );
}

/// 只用于「点缓存小说」用例的内存离线区：stats/缺口立即返回，不碰真实磁盘。
class _DownloadingBookStore extends OfflineBookStore {
  _DownloadingBookStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  final Map<String, OfflineBook> _books = <String, OfflineBook>{};

  /// 只写内存：真实 store 会落到 path_provider 目录，widget 测试里不会完成。
  @override
  Future<void> begin(OfflineBook book) async {
    _books[book.bookId] = book;
  }

  @override
  Future<OfflineBook?> read(String bookId) async => _books[bookId];

  @override
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async =>
      null;

  /// 全部章节都还没下：下载器会从头开始，任务进入 running。
  @override
  Future<List<String>> missingChapterIds(
    String bookId,
    List<Chapter> chapters,
  ) async => [for (final chapter in chapters) chapter.id];

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() async => OfflineStats(
    count: _books.length,
    bytes: 0,
    capBytes: OfflineBookStore.novelCapBytes,
  );
}

/// 卡住第一批正文的假网络：下载停在「进行中」，可以稳定断言「缓存中」。
///
/// 不用 Future.delayed：widget 测试结束时未完成的定时器会直接失败。
class _GatedOfflineNetwork implements OfflineNetwork {
  final Completer<void> _gate = Completer<void>();

  @override
  Future<Map<String, ChapterContent>> chaptersBatch(
    List<Chapter> chapters, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    await _gate.future;
    return const {};
  }

  @override
  Future<ChapterContent> chapter(String chapterId, {String title = ''}) async =>
      throw UnimplementedError('批量接口已覆盖，用例不需要单章回退');

  @override
  Future<VideoSource> videoSource(String episodeId, {int? maxHeight}) async =>
      throw UnimplementedError('小说下载不取视频流');

  @override
  Future<OfflineVideoStream> openVideoStream(String url) async =>
      throw UnimplementedError('小说下载不取视频流');
}
