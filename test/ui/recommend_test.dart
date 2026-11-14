import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/category_tab_bar.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/widgets/surface_card.dart';
import 'package:novel_playlet/app/widgets/top_glow.dart';
import 'package:novel_playlet/features/cache/cache_center_page.dart';
import 'package:novel_playlet/features/feed/feed_search_field.dart';
import 'package:novel_playlet/features/recommend/recommend_layout.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/search/search_page.dart';
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

/// 前 [count] 张卡片各自的左边距去重后的列表：列数 = 左边距种类数。
///
/// 瀑布流里同一列卡片的 x 相同，所以这比数卡片总数更直接；用前几张卡是因为
/// 首屏内容一定已布局（不依赖滚动）。
List<double> _firstCardLefts(WidgetTester tester, {required int count}) {
  final cards = tester
      .widgetList<NovelGridCard>(find.byType(NovelGridCard))
      .take(count);
  return {for (final card in cards) tester.getTopLeft(find.byWidget(card)).dx}
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
    expect(find.byType(TopGlow), findsOneWidget, reason: '顶部固定模块带氛围渐变');
    // 合并后推荐态不再有「为你推荐 / 短剧推荐」区块标题。
    expect(find.text('为你推荐'), findsNothing);
    expect(find.text('短剧推荐'), findsNothing);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend.png'),
    );
  });

  testWidgets('推荐页-小说卡：作者固定一行，推荐理由/热度各自有就显示', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    // fake 推荐流：每本都有作者；i%3==0 带推荐理由，i%3==1 带 rank_score。
    expect(find.text('1万热度'), findsWidgets, reason: '热度有就显示（i=1）');
    expect(find.text('巅峰榜No.3'), findsWidgets, reason: '推荐理由有就显示（i=3）');
    expect(find.text('烽火戏诸侯'), findsWidgets, reason: '作者无条件显示');
    // 双列：热度右对齐到作者同一行，行尾不空着；作者不被顶掉。
    final heatCard = find.ancestor(
      of: find.text('1万热度').first,
      matching: find.byType(NovelGridCard),
    );
    final authorInHeatCard = find.descendant(
      of: heatCard,
      matching: find.text('烽火戏诸侯'),
    );
    expect(authorInHeatCard, findsOneWidget, reason: '作者与热度显示在同一张卡上');
    expect(
      tester.getTopLeft(find.text('1万热度').first).dy,
      closeTo(tester.getTopLeft(authorInHeatCard).dy, 0.5),
      reason: '热度与作者同一行',
    );
    expect(
      tester.getTopLeft(find.text('1万热度').first).dx,
      greaterThan(tester.getTopLeft(authorInHeatCard).dx),
      reason: '热度靠右',
    );
    final reasonCard = find.ancestor(
      of: find.text('巅峰榜No.3').first,
      matching: find.byType(NovelGridCard),
    );
    expect(
      find.descendant(of: reasonCard, matching: find.text('卖报小郎君')),
      findsOneWidget,
      reason: '作者与推荐理由显示在同一张卡上',
    );
    // 评分从作者行移到封面右上角角标（i=1 8.8 / i=2 9.3）。
    expect(find.text('8.8分'), findsWidgets, reason: '评分在封面右上角角标');
    expect(find.text('9.3分'), findsWidgets, reason: '评分在封面右上角角标');
  });

  testWidgets('推荐页-短剧卡：集数固定一行，推荐理由/热度各自有就显示', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    // i=3/6/9 带推荐理由，i=1 带 rec_text（热度），i=2 只有集数。
    expect(find.text('全 43 集'), findsOneWidget, reason: '集数固定一行');
    expect(find.text('系列剧·40万人在追'), findsWidgets, reason: '推荐理由单独一行，有就显示');
    expect(find.text('全 41 集'), findsOneWidget);
    expect(find.text('10万热度'), findsOneWidget, reason: '热度有就显示');
    expect(
      tester.getTopLeft(find.text('10万热度')).dy,
      closeTo(tester.getTopLeft(find.text('全 41 集')).dy, 0.5),
      reason: '双列：热度与集数同一行（右对齐）',
    );
    expect(find.text('全 42 集'), findsOneWidget, reason: '没有理由/热度时只显示集数');
    // 评分进封面角标（短剧 i=1 8.0 / i=2 8.2）。
    expect(find.text('8.0分'), findsWidgets);
    expect(find.text('8.2分'), findsWidgets);
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
    expect(
      find.byType(CategoryTabBar),
      findsOneWidget,
      reason: '与我的页共用同一套 tabs',
    );
    // 首个 tab 的文字左边缘与搜索框左边缘对齐（同一个内容留白）。
    expect(
      tester.getTopLeft(find.text('小说')).dx,
      closeTo(tester.getTopLeft(find.byType(FeedSearchField)).dx, 0.5),
      reason: '首个 tab 文字应与搜索框左对齐',
    );
    final scrollView = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(CategoryTabBar),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(
      scrollView.scrollDirection,
      Axis.horizontal,
      reason: '分类 tabs 必须能左右滑动',
    );
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
    final tabsBottom = tester.getBottomLeft(find.byType(CategoryTabBar)).dy;
    expect(
      tabsBottom,
      lessThanOrEqualTo(100),
      reason: '搜索框 + tabs + 间距应压到 100pt 以内，实际 $tabsBottom',
    );
  });

  /// 搜索框常驻顶部：上滑多深都不收起、位置不挪，tabs 照旧在。
  testWidgets('推荐页-搜索框常驻顶部不随滚动收起', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    final before = tester.getTopLeft(find.byType(FeedSearchField));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索框必须常驻，不能随上滑收起',
    );
    expect(find.text('小说'), findsOneWidget, reason: 'tabs 必须一起保留');
    expect(
      tester.getTopLeft(find.byType(FeedSearchField)),
      before,
      reason: '常驻时搜索框位置不应变化',
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsOneWidget);
  });

  /// 顶部渐变必须盖住状态栏（安全区）那一条，不能从状态栏下方才开始。
  testWidgets('推荐页-顶部渐变盖住状态栏', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44);
    await pumpPreview(tester, const RecommendPage());
    final glow = tester.getRect(find.byType(TopGlow));
    expect(glow.top, 0, reason: '渐变必须从屏幕最顶端开始');
    expect(
      glow.height,
      greaterThanOrEqualTo(116 + 44),
      reason: '高度要包含状态栏安全区，否则顶部会留一条纯白',
    );
  });

  /// 顶部搜索框是只读入口：点一下（输入区或左图标都算）进独立搜索页，
  /// 推荐页本身不再做内联搜索。
  testWidgets('推荐页-点搜索框进独立搜索页', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    expect(find.byType(FeedSearchField), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.text('搜索小说 / 短剧'), findsWidgets);
  });

  /// 搜索页返回后推荐流不重拉、搜索词不残留（搜索词随页面 autoDispose 清掉）。
  testWidgets('推荐页-搜索页返回不重拉推荐流且搜索词已清空', (tester) async {
    final fake = FakePreviewTransport();
    await pumpPreview(tester, const RecommendPage(), transport: fake);
    int feedCalls() => fake.calls
        .where((call) => call.startsWith('/api/v1/recommend/homepage'))
        .length;
    final before = feedCalls();

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.byType(SearchPage), findsNothing);
    expect(feedCalls(), before, reason: '搜索/返回不应重拉推荐流');

    // 再进搜索页：上一次的搜索词已清掉（不显示结果），但关键词进了搜索历史。
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('剑来'), findsOneWidget);
    expect(find.byType(NovelGridCard), findsNothing, reason: '搜索词应已清空');
  });

  /// 搜索框轮播热词：热词只做 placeholder，不写进输入框；点进搜索页时把
  /// 当前轮播到的那条带过去，搜索页从同一条接着显示。
  testWidgets('推荐页-搜索框轮播热词，点进搜索页带过去', (tester) async {
    final fake = FakePreviewTransport()
      ..cueWords = ['热词一', '热词二']
      ..cueRotateIntervalMs = 500;
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: fake,
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('热词一'), findsOneWidget);

    // 到一个轮播间隔：淡入淡出后换成下一条。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('热词二'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SearchPage), matching: find.text('热词二')),
      findsOneWidget,
      reason: '搜索页占位应从推荐页当前那条热词接着显示',
    );
  });

  /// 搜索框右侧的下载图标入口直接进缓存中心（不再是一段文字）。
  testWidgets('推荐页-下载图标入口打开缓存中心', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    expect(find.text('已缓存'), findsNothing, reason: '入口只放图标，不占文字');
    final entry = find.byTooltip('已缓存');
    expect(entry, findsOneWidget);
    expect(
      find.descendant(
        of: entry,
        matching: find.byIcon(Icons.download_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(CacheCenterPage), findsOneWidget);
  });

  /// 封面尺寸回归：推荐流按内容域原生比例出封面（小说 240×320、短剧/漫剧 400×571，都是高/宽）。
  ///
  /// 以前统一裁成 kCoverAspect（11:8），是为了让三个分类的封面同宽同高、切 tab
  /// 不跳；改成不定高瀑布流后这个约束没必要了：按上游原生比例出图不裁封面，
  /// 小说会比短剧/漫剧略矮。列宽仍然只由列数决定，同一分类里封面尺寸必须一致。
  /// 切分类后旧页面会被 TabBarView 保活，所以按卡片类型圈定当前分类的封面。
  testWidgets('封面尺寸-推荐流按内容域原生比例', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final novel = _gridCoverSizes(tester, novel: true);
    expect(novel, isNotEmpty);
    expect(novel.map((size) => size.width).toSet(), hasLength(1));
    expect(
      novel.first.height / novel.first.width,
      closeTo(kNovelCoverAspect, 0.001),
      reason: '小说封面按 240×320（高/宽 4:3）出图，不再裁成 11:8',
    );

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    final drama = _gridCoverSizes(tester, novel: false);
    expect(drama, isNotEmpty);
    expect(drama.map((size) => size.width).toSet(), hasLength(1));
    expect(
      drama.first.height / drama.first.width,
      closeTo(kVideoCoverAspect, 0.001),
      reason: '短剧/漫剧封面按 400×571 原生比例出图',
    );

    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    final anime = _gridCoverSizes(tester, novel: false);
    expect(anime, isNotEmpty);

    expect(drama.first.width, novel.first.width, reason: '同一套列宽，封面宽度必须一致');
    expect(anime.first.width, novel.first.width, reason: '同一套列宽，封面宽度必须一致');
    expect(
      drama.first.height,
      greaterThan(novel.first.height),
      reason: '短剧原生比例（高/宽 571/400 ≈ 1.4275）比小说（4/3 ≈ 1.333）更高',
    );
  });

  /// 默认双列瀑布流：前两张卡片分列左右，卡片是白底卡。
  testWidgets('推荐页-默认双列瀑布流', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    expect(
      _firstCardLefts(tester, count: 2),
      hasLength(2),
      reason: '默认双列：前两张卡片左右各一张',
    );
    expect(find.byType(AppSurfaceCard), findsWidgets, reason: '推荐卡是白底卡片');
  });

  /// 布局偏好是全局状态：设置页把布局切成三列后，推荐页立即按三列排版。
  testWidgets('推荐页-三列布局每行三张', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      extraOverrides: [
        recommendLayoutProvider.overrideWith(
          () => RecommendLayoutController(initialLayout: RecommendLayout.three),
        ),
      ],
    );
    expect(
      _firstCardLefts(tester, count: 3),
      hasLength(3),
      reason: '三列：前三张卡片各占一列',
    );
  });

  /// 切列数立即生效，不需要重新进页面（推荐页 watch 同一个 provider）。
  testWidgets('推荐页-切换布局立即生效', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RecommendPage)),
    );
    container
        .read(recommendLayoutProvider.notifier)
        .setLayout(RecommendLayout.three);
    await tester.pumpAndSettle();
    expect(_firstCardLefts(tester, count: 3), hasLength(3));
  });

  /// 三列基线：列数换掉后卡宽变窄，锁住整页观感。
  testWidgets('推荐页-三列', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      extraOverrides: [
        recommendLayoutProvider.overrideWith(
          () => RecommendLayoutController(initialLayout: RecommendLayout.three),
        ),
      ],
    );
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend_three_columns.png'),
    );
  });

  /// 深色基线：白底卡在暗色下换成 surfaceContainerHigh，靠底色差分层（不画阴影）。
  testWidgets('推荐页-深色', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('../goldens/recommend_dark.png'),
    );
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
    final hint = tester.getRect(find.text('搜索小说 / 短剧'));
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

  testWidgets('推荐页-内容区左右滑动切分类', (tester) async {
    await pumpPreview(tester, const RecommendPage());
    await tester.drag(find.byType(TabBarView), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('太奶奶'), findsWidgets);

    await tester.drag(find.byType(TabBarView), const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.text('搜索小说 / 短剧'), findsOneWidget);
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
