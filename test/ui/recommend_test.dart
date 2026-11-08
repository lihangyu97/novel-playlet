import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/features/feed/feed_results.dart';
import 'package:novel_playlet/features/feed/feed_search_field.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 推荐页预览与交互：三个分类的列表/搜索、顶部收起、封面尺寸与 Hero。
///
/// 更新基线：`flutter test --update-goldens test/ui/recommend_test.dart`。
/// 当前分类网格里的封面尺寸。按卡片类型圈定（小说分类是
/// [NovelGridCard]，短剧/漫剧是 [VideoCard]），避免以后同屏出现混合卡片时
/// 拿错对象；保活的隐藏页默认被 finder 的 skipOffstage 跳过。
List<Size> _gridCoverSizes(WidgetTester tester, {required bool novel}) {
  final cards = novel ? find.byType(NovelGridCard) : find.byType(VideoCard);
  final covers = find.descendant(of: cards, matching: find.byType(NovelCover));
  return tester
      .widgetList<NovelCover>(covers)
      .map((cover) => Size(cover.width, cover.height))
      .toList();
}

/// 搜索结果横向列表里的封面尺寸（[FeedResultTile] 圈定）。
List<Size> _searchCoverSizes(WidgetTester tester) {
  final covers = find.descendant(
    of: find.byType(FeedResultTile),
    matching: find.byType(NovelCover),
  );
  return tester
      .widgetList<NovelCover>(covers)
      .map((cover) => Size(cover.width, cover.height))
      .toList();
}

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('推荐页-小说分类', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    // 合并后推荐态不再有「为你推荐 / 短剧推荐」区块标题。
    expect(find.text('为你推荐'), findsNothing);
    expect(find.text('短剧推荐'), findsNothing);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend.png'),
    );
  });

  testWidgets('推荐页-小说卡元信息按「推荐理由 → 热度 → 作者 · 评分」', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    // fake 推荐流：i%3==1 带 rank_score，i%3==2 只有评分，i%3==0 带推荐理由。
    expect(find.text('1万热度'), findsOneWidget, reason: '无理由时展示热度');
    expect(
      find.text('爱潜水的乌贼 · 9.3分'),
      findsOneWidget,
      reason: '无理由/热度时退回作者 · 评分',
    );
    expect(find.text('巅峰榜No.3'), findsOneWidget, reason: '有推荐理由时优先展示');
  });

  testWidgets('推荐页-短剧卡元信息按同一优先级（理由 → 热度 → 集数 · 评分）', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    // 集数永远在最前；i=3/6/9 带推荐理由，i=1 带 rec_text，i=2 只有集数+评分。
    expect(
      find.text('全 43 集 · 系列剧·40万人在追'),
      findsOneWidget,
      reason: '集数在最前，有推荐理由时优先展示',
    );
    expect(
      find.text('全 41 集 · 10万热度'),
      findsOneWidget,
      reason: '无理由时展示「集数 + rec_text 热度」',
    );
    expect(
      find.text('全 42 集 · 8.2分'),
      findsOneWidget,
      reason: '没有理由/热度时退回「集数 · 评分」',
    );
  });

  testWidgets('推荐页-短剧分类', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    expect(find.textContaining('太奶奶'), findsWidgets);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend_drama.png'),
    );
  });

  testWidgets('推荐页-漫剧分类', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(find.textContaining('动态漫'), findsWidgets);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend_anime.png'),
    );
  });

  testWidgets('推荐页-分类 tabs 横向可滚动', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.isScrollable, isTrue, reason: '分类 tabs 必须能左右滑动');
    expect(find.byType(Tab), findsNWidgets(3));
    for (final label in ['小说', '短剧', '漫剧']) {
      expect(find.text(label), findsOneWidget, reason: '缺少分类 $label');
    }
  });

  /// A：顶部尺寸收紧——搜索框 40pt、tabs 36pt，搜索+tabs+间距压到 100pt 内。
  testWidgets('推荐页-顶部高度收紧', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    expect(
      tester.getSize(find.byType(FeedSearchField)).height,
      FeedSearchField.height,
    );
    expect(FeedSearchField.height, 40, reason: '搜索框高度应为 40');
    final tabsBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
    expect(
      tabsBottom,
      lessThanOrEqualTo(100),
      reason: '搜索框 + tabs + 间距应压到 100pt 以内，实际 $tabsBottom',
    );
  });

  /// C：上滑浏览时搜索框整条收起，tabs 保留；回到顶部再展开。
  testWidgets('推荐页-上滑收起搜索框、tabs 保留、回顶展开', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    expect(find.byType(FeedSearchField), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing, reason: '上滑后搜索框应收起');
    expect(find.text('小说'), findsOneWidget, reason: 'tabs 必须保留，否则切不了分类');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsOneWidget, reason: '回到顶部应重新展开');
  });

  /// 搜索态不能收起：输入框正在被使用，藏起来用户就不知道自己在搜什么。
  testWidgets('推荐页-搜索态下滚动不收起搜索框', (tester) async {
    final fake = FakePreviewTransport()..searchItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索态必须保持搜索框可见',
    );
  });

  /// 各分类的折叠状态独立：短剧没滚过要展开，切回已滚动的小说要继续收起。
  /// 收起后左右切分类不能把搜索框弹回来：折叠是页面级状态，与各分类
  /// 自己的滚动位置无关（即使切到的分类还停在顶部）。
  testWidgets('推荐页-收起后切分类保持收起', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing);

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsNothing,
      reason: '切到未滚动的分类也不应重新展开搜索框',
    );
    expect(find.text('短剧'), findsOneWidget);

    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing, reason: '切回来仍保持收起');
  });

  /// 深处回落立即展开：滚得很深时，往回滑的第一下就要看到搜索框，
  /// 不能等一路滚回顶部才展开。
  testWidgets('推荐页-深滚动后往回滑立即展开', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing);
    final deepOffset = verticalOffset(tester);
    expect(deepOffset, greaterThan(300), reason: '前置条件：确实滚了很远');

    // 往回滑一小段（仍在很深的位置）：搜索框必须立刻出现。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 80));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsOneWidget, reason: '往回滑应立即展开搜索框');
    expect(
      verticalOffset(tester),
      greaterThan(300),
      reason: '展开不依赖滚回顶部：此时仍应处于深滚动位置',
    );
  });

  /// 封面尺寸回归：三个分类的推荐流封面必须同宽同高。
  ///
  /// 上游原生比例不同（小说 240×320 = 3:4，短剧 400×571 ≈ 1.427），以前两条
  /// 流各用各的 `coverAspect`；合并成一个页面后更不能出现切分类封面大小跳变。
  /// 切分类后旧页面会被 TabBarView 保活，所以按卡片类型圈定当前分类的封面。
  testWidgets('封面尺寸-三个分类的推荐流一致', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final novel = _gridCoverSizes(tester, novel: true);
    expect(novel, isNotEmpty);
    expect(novel.map((size) => size.width).toSet(), hasLength(1));
    expect(
      novel.first.height / novel.first.width,
      closeTo(kCoverAspect, 0.001),
    );

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    final drama = _gridCoverSizes(tester, novel: false);
    expect(drama, isNotEmpty);
    expect(drama.map((size) => size.width).toSet(), hasLength(1));
    expect(
      drama.first.height / drama.first.width,
      closeTo(kCoverAspect, 0.001),
    );

    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    final anime = _gridCoverSizes(tester, novel: false);
    expect(anime, isNotEmpty);

    expect(drama.first, novel.first, reason: '短剧与小说封面尺寸必须一致');
    expect(anime.first, novel.first, reason: '漫剧与小说封面尺寸必须一致');
  });

  /// 搜索态也统一：三个分类都是横向列表 + 同一套条目，封面同宽同高。
  testWidgets('封面尺寸-三个分类的搜索结果一致', (tester) async {
    Future<Size> searchOn(String query, {String? tab}) async {
      await pumpPreview(tester, const RecommendPage());
      if (tab != null) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextField), query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final sizes = _searchCoverSizes(tester);
      expect(sizes, isNotEmpty);
      expect(sizes.map((size) => size.width).toSet(), hasLength(1));
      expect(
        sizes.first.width,
        FeedResultTile.coverWidth,
        reason: '搜索结果封面宽度应走 FeedResultTile.coverWidth',
      );
      expect(
        sizes.first.height / sizes.first.width,
        closeTo(kCoverAspect, 0.001),
      );
      return sizes.first;
    }

    final novel = await searchOn('剑来');
    final drama = await searchOn('太奶奶', tab: '短剧');
    final anime = await searchOn('漫剧', tab: '漫剧');

    expect(drama, novel, reason: '短剧与小说搜索结果封面尺寸必须一致');
    expect(anime, novel, reason: '漫剧与小说搜索结果封面尺寸必须一致');
  });

  group('封面 Hero 飞入', () {
    testWidgets('推荐页-卡片封面都带唯一 Hero tag', (tester) async {
      await pumpPreview(tester, const RecommendPage());
      final cards = tester
          .widgetList<NovelGridCard>(find.byType(NovelGridCard))
          .toList();
      expect(cards, isNotEmpty);
      final tags = cards.map((card) => card.heroTag).toList();
      expect(tags.every((tag) => tag != null), isTrue);
      expect(tags.toSet().length, tags.length, reason: '同一屏封面 Hero tag 必须唯一');
      expect(tags.first, 'cover-novel-recommend-novel-1');
    });
  });

  testWidgets('推荐页-搜索框内容垂直居中', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final hint = tester.getRect(find.text('搜索书名/作者'));
    final icon = tester.getRect(find.byIcon(Icons.search_rounded));
    final field = tester.getRect(find.byType(TextField));
    expect(
      (hint.center.dy - icon.center.dy).abs(),
      lessThan(1.2),
      reason: '提示文字与放大镜必须同一条水平中线',
    );
    expect(
      (hint.center.dy - field.center.dy).abs(),
      lessThan(1.2),
      reason: '提示文字必须在输入区垂直居中',
    );
  });

  testWidgets('推荐页-搜索框输入前后高度不变', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final before = tester.getSize(find.byType(TextField)).height;
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.pump();
    final after = tester.getSize(find.byType(TextField)).height;
    expect(after, before, reason: '输入后出现清空按钮不应把搜索框撑高');
  });

  testWidgets('推荐页-搜索态', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend_search.png'),
    );
  });

  testWidgets('推荐页-内容区左右滑动切分类', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.drag(find.byType(TabBarView), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.text('搜索短剧'), findsOneWidget);
    expect(find.textContaining('太奶奶'), findsWidgets);

    await tester.drag(find.byType(TabBarView), const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.text('搜索书名/作者'), findsOneWidget);
  });

  testWidgets('推荐页-切分类回来保留滚动位置', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    expect(verticalOffset(tester), 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -420));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final scrolled = verticalOffset(tester);
    expect(scrolled, greaterThan(100), reason: '多屏内容应该能滚动');

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(
      verticalOffset(tester),
      closeTo(scrolled, 0.5),
      reason: '保活后滚动位置必须保持',
    );
  });

  /// 搜索结果的滚动不能污染推荐流的折叠状态：取消搜索后推荐流还在顶部，
  /// 搜索框必须重新展开（不能还停在「搜索时滚过」的收起态）。
  testWidgets('推荐页-取消搜索后按推荐流位置展开', (tester) async {
    final fake = FakePreviewTransport()..searchItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(verticalOffset(tester), greaterThan(100), reason: '搜索结果应能滚动');
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索态滚动时输入框必须保持可见',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '取消搜索后推荐流在顶部，搜索框应展开而不是继承搜索结果的滚动位置',
    );
  });

  testWidgets('推荐页-取消搜索回显推荐流且不重新请求', (tester) async {
    final fake = FakePreviewTransport();
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    int countOf(String prefix) =>
        fake.calls.where((call) => call.startsWith(prefix)).length;

    expect(countOf('/api/v1/search'), 0);

    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final searchCalls = countOf('/api/v1/search');
    expect(searchCalls, greaterThanOrEqualTo(1));

    final feedCalls = countOf('/api/v1/recommend/homepage');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('取消'), findsNothing);
    expect(countOf('/api/v1/search'), searchCalls, reason: '取消搜索只回显快照，不应再发请求');
    expect(
      countOf('/api/v1/recommend/homepage'),
      feedCalls,
      reason: '取消搜索不应重新拉推荐流',
    );
    expect(find.text('剑来'), findsWidgets, reason: '应回到推荐流');
  });

  testWidgets('推荐页-搜索失败后换关键词先显示 loading 而不是旧错误', (tester) async {
    final fake = FakePreviewTransport()
      ..failingQueries.add('失败')
      ..responseDelay = const Duration(milliseconds: 60);
    await pumpPreview(tester, const RecommendPage(), transport: fake);

    await tester.enterText(find.byType(TextField), '失败');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('boom'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // 请求还没回来：必须显示 loading，而不是把上一次的 ErrorView 钉住。
    await tester.pump();
    expect(find.text('boom'), findsNothing);
    expect(find.text('搜索中…'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('搜索结果 剑来'), findsOneWidget);
  });

  testWidgets('推荐页-首屏失败立即显示错误页（不等待自动重试）', (tester) async {
    // Riverpod 3 默认对异常自动重试 10 次（约 38 秒），期间状态一直是 loading，
    // 错误页会被推迟。这里不用 pumpAndSettle（会把自动重试跑完），固定时长
    // 观察：首请求失败后必须马上出现 ErrorView，且只发过一次请求。
    final fake = FakePreviewTransport()..failRecommend = true;
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: fake,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('boom'), findsOneWidget);
    expect(
      fake.calls
          .where((call) => call.startsWith('/api/v1/recommend/homepage'))
          .length,
      1,
      reason: '关闭自动重试后，失败应立即交给用户手动重试',
    );
  });
}
