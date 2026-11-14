import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/states.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/search/search_page.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 独立搜索页：空态、三分类各一行、卡片尺寸、加载/失败/重试/换词/清空。
///
/// 更新基线：`flutter test --update-goldens test/ui/search_test.dart`。
Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// 两行结果都是横向可滑的。
List<SingleChildScrollView> _horizontalRows(WidgetTester tester) => tester
    .widgetList<SingleChildScrollView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    )
    .toList();

/// 当前预览逻辑屏宽（不是写死 390，测试视图尺寸改了能给出清楚失败）。
double _screenWidth(WidgetTester tester) =>
    tester.view.physicalSize.width / tester.view.devicePixelRatio;

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('搜索页-空态', (tester) async {
    await pumpPreview(tester, const SearchPage());
    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.textContaining('输入关键词'), findsOneWidget);
    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('../goldens/search_empty.png'),
    );
  });

  testWidgets('搜索页-搜索历史：提交后清空显示关键词，点击可直接重搜', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');
    expect(find.byType(NovelGridCard), findsWidgets);

    // 清空输入回到搜索历史。
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('剑来'), findsOneWidget);
    expect(find.byType(EmptyView), findsNothing, reason: '有历史时不再显示引导空态');

    // 点历史关键词直接重新搜索。
    await tester.tap(find.text('剑来'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(NovelGridCard), findsWidgets);
    expect(find.text('搜索历史'), findsNothing);
  });

  testWidgets('搜索页-启动时恢复落盘的搜索历史，可一键清空', (tester) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': <String>['剑来', '斗破'],
    });
    await pumpPreview(tester, const SearchPage());
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('斗破'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('搜索历史'), findsNothing);
    expect(find.byType(EmptyView), findsOneWidget);
  });

  testWidgets('搜索页-小说 / 短剧两行从上到下各一行横向卡片', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');

    // 分类标题只在各行的 section header 出现，只有 小说 → 短剧 两行（漫剧不再单列）。
    final novelY = tester.getTopLeft(find.text('小说')).dy;
    final dramaY = tester.getTopLeft(find.text('短剧')).dy;
    expect(novelY, lessThan(dramaY));
    expect(find.text('漫剧'), findsNothing, reason: '漫剧不再单列一行');

    // 小说行用小说卡，短剧行用视频卡（复用首页同款卡片）。
    expect(find.byType(NovelGridCard), findsWidgets);
    expect(find.byType(VideoCard), findsWidgets);

    // 两行都能左右滑。
    expect(_horizontalRows(tester), hasLength(2));

    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('../goldens/search_results.png'),
    );
  });

  testWidgets('搜索页-短剧行直接展示上游混排结果（含漫剧卡片）', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');

    // 短剧搜索 tab 本身是短剧+漫剧混排：不单列漫剧行后，这一行原样展示，
    // 不丢内容、也不再多打一个同样的请求。
    final videos = tester
        .widgetList<VideoCard>(find.byType(VideoCard))
        .toList();
    expect(videos, isNotEmpty);
    expect(videos.any((card) => !card.item.isManju), isTrue, reason: '混排里有短剧');
    expect(videos.any((card) => card.item.isManju), isTrue, reason: '混排里有漫剧卡片');
    expect(find.text('漫剧'), findsNothing, reason: '卡面也不再出现分类名标签');
  });

  testWidgets('搜索页-一屏露出约 3.5 张卡片', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');

    // 卡宽 = (屏宽 - 两侧留白 - 3 个卡间距) / 3.5。
    final screenWidth = _screenWidth(tester);
    final expected = SearchPage.cardWidthFor(screenWidth);
    expect(expected, closeTo(100, 0.01));
    final card = tester.getSize(find.byType(NovelGridCard).first);
    expect(card.width, closeTo(expected, 0.01));

    // 第 4 张卡右边缘已经超出屏幕：一屏只完整露出 3 张 + 半张。
    final fourth = find.byType(NovelGridCard).at(3);
    final fourthLeft =
        SearchPage.rowPadding + 3 * (expected + SearchPage.cardGap);
    expect(tester.getTopLeft(fourth).dx, closeTo(fourthLeft, 0.01));
    expect(tester.getTopLeft(fourth).dx + expected, greaterThan(screenWidth));
  });

  testWidgets('搜索页-卡片行可以左右滑', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');

    final firstCard = find.byType(NovelGridCard).first;
    final before = tester.getTopLeft(firstCard).dx;
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(firstCard).dx,
      lessThan(before),
      reason: '第一行必须能往左滑，露出后面的卡片',
    );
  });

  testWidgets('搜索页-点小说卡进小说详情页', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');
    await tester.tap(find.byType(NovelGridCard).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.byType(DetailPage), findsOneWidget);
  });

  testWidgets('搜索页-点短剧卡进短剧详情页', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');
    await tester.tap(find.byType(VideoCard).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.byType(VideoDetailPage), findsOneWidget);
  });

  testWidgets('搜索页-热词占位（轮播第一条）', (tester) async {
    final fake = FakePreviewTransport()
      ..cueWords = ['诡秘之主最新章', '十日终焉']
      // 只锁第一条形态，测试期间不翻。
      ..cueRotateIntervalMs = 60000;
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('诡秘之主最新章'), findsOneWidget);
    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('../goldens/search_cue.png'),
    );
  });

  testWidgets('搜索页-占位从带进来的热词开始', (tester) async {
    final fake = FakePreviewTransport()..cueWords = ['热词甲', '热词乙'];
    await pumpPreview(
      tester,
      const SearchPage(initialCueWord: '热词乙'),
      transport: fake,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('热词乙'), findsOneWidget);
    expect(find.text('热词甲'), findsNothing, reason: '从带进来的那条开始，不跳回第一条');
  });

  testWidgets('搜索页-空输入提交直接搜当前占位热词', (tester) async {
    final fake = FakePreviewTransport()
      ..cueWords = ['热词甲', '热词乙']
      // 测试期间不翻，保证提交的就是首帧那条。
      ..cueRotateIntervalMs = 60000;
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('热词甲'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      fake.calls.any((call) => call.contains(Uri.encodeQueryComponent('热词甲'))),
      isTrue,
      reason: '空输入提交应把当前占位热词当成关键词发请求',
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '热词甲', reason: '实际搜索的词要填进输入框');
  });

  testWidgets('搜索页-加载中显示骨架色块（与真卡同宽同高）', (tester) async {
    final fake = FakePreviewTransport()
      ..responseDelay = const Duration(milliseconds: 300);
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 20));

    for (final name in ['novel', 'drama']) {
      expect(
        find.byKey(ValueKey('search-skeleton-$name')),
        findsOneWidget,
        reason: '$name 行加载中应显示骨架占位',
      );
    }
    expect(find.byType(NovelGridCard), findsNothing);
    await expectLater(
      find.byType(SearchPage),
      matchesGoldenFile('../goldens/search_loading.png'),
    );

    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('search-skeleton-novel')), findsNothing);
    expect(find.byType(NovelGridCard), findsWidgets, reason: '请求回来后换成真卡');
  });

  testWidgets('搜索页-视频卡不展示推荐理由，只留集数+热度', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');

    // 推荐理由字段（漫剧卡是「漫剧」、短剧卡是「上新」）在搜索卡上整体隐藏。
    expect(find.text('漫剧'), findsNothing);
    expect(find.text('上新'), findsNothing);
    // 集数与热度保留。
    expect(find.text('4105万热度'), findsWidgets);
  });

  testWidgets('搜索页-搜索失败显示错误与重试', (tester) async {
    final fake = FakePreviewTransport()..failingQueries.add('失败');
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await _submit(tester, '失败');
    expect(find.text('boom'), findsNWidgets(2), reason: '两行各自失败、各自可重试');
    expect(find.text('重试'), findsNWidgets(2));
  });

  testWidgets('搜索页-失败后点重试能恢复该行', (tester) async {
    final fake = FakePreviewTransport()..failingQueries.add('失败');
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await _submit(tester, '失败');

    // 模拟网络恢复后点小说行的「重试」：只有这一行恢复，短剧行保持错误态。
    fake.failingQueries.clear();
    await tester.tap(find.text('重试').first);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byType(NovelGridCard), findsWidgets, reason: '重试后小说行应出结果');
    expect(find.byType(VideoCard), findsNothing, reason: '另一行不该被一起重拉');
    expect(find.text('重试'), findsNWidgets(1));
  });

  testWidgets('搜索页-三个分类都没结果时各自显示空态', (tester) async {
    final fake = FakePreviewTransport()..searchItemCount = 0;
    await pumpPreview(tester, const SearchPage(), transport: fake);
    await _submit(tester, '没有这本书');
    expect(find.text('没有找到相关小说'), findsOneWidget);
    expect(find.text('没有找到相关短剧'), findsOneWidget);
    expect(find.text('没有找到相关漫剧'), findsNothing, reason: '漫剧行已去掉');
  });

  testWidgets('搜索页-清空输入回到搜索历史', (tester) async {
    await pumpPreview(tester, const SearchPage());
    await _submit(tester, '剑来');
    expect(find.byType(NovelGridCard), findsWidgets);

    await tester.tap(find.byIcon(Icons.cancel_rounded));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('剑来'), findsOneWidget);
    expect(find.byType(NovelGridCard), findsNothing);
  });

  testWidgets('搜索页-换关键词只显示新关键词的结果', (tester) async {
    // 延迟让两个关键词的请求重叠：旧关键词的响应在新关键词之后才到。
    final fake = FakePreviewTransport()
      ..responseDelay = const Duration(milliseconds: 40);
    await pumpPreview(tester, const SearchPage(), transport: fake);

    await tester.enterText(find.byType(TextField), 'AAA');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.enterText(find.byType(TextField), 'BBB');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(
      find.textContaining('AAA'),
      findsNothing,
      reason: '旧关键词迟到的结果不能重新画出来',
    );
    expect(find.textContaining('BBB'), findsWidgets, reason: '应显示新关键词的结果');

    // 旧关键词的迟到响应已被丢弃，但 fake transport 的定时器还在：补一次 pump
    // 让它落地，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(milliseconds: 100));
  });
}
