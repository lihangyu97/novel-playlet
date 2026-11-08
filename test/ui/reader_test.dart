import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
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
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('../goldens/reader_toolbar.png'),
    );
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
}
