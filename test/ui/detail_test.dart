import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/detail/detail_common.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 小说详情页预览：Hero 飞入、加载态、作者信息行与封面背景。
///
/// 更新基线：`flutter test --update-goldens test/ui/detail_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('封面 Hero 飞入', () {
    testWidgets('小说列表点进详情：封面飞入并在返回时飞回', (tester) async {
      final fake = FakePreviewTransport()
        ..bookCoverUrl = 'https://example.com/cover-1.jpg';
      await pumpPreview(tester, const RecommendPage(), transport: fake);
      final card = tester.widget<NovelGridCard>(
        find.byType(NovelGridCard).first,
      );
      final tag = card.heroTag!;

      await tester.tap(find.byType(NovelGridCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '进详情时应在飞行',
      );
      final detailHero = tester.widget<Hero>(
        find
            .descendant(
              of: find.byType(DetailPage),
              matching: find.byType(Hero),
            )
            .first,
      );
      expect(detailHero.tag, tag, reason: '详情页封面必须用同一个 tag 接住 Hero');

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.text(card.item.title), findsWidgets);

      // 返回时 Hero 反向飞回列表卡片。
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '从详情返回时应执行反向封面飞行',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byType(NovelGridCard), findsWidgets);
    });

    testWidgets('返回落位时 shuttle 下两角是直角，不会被卡片接管时「圆变尖」', (tester) async {
      final fake = FakePreviewTransport()
        ..bookCoverUrl = 'https://example.com/cover-1.jpg';
      await pumpPreview(tester, const RecommendPage(), transport: fake);
      await tester.tap(find.byType(NovelGridCard).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      // 返程飞到一半：shuttle 仍在，下两角必须已经是直角（卡片封面形状），
      // 上两角保留卡片顶部圆角，Hero 结束时不会出现「下两角由圆变尖」。
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final shuttle = tester.widget<ClipRRect>(
        find.byKey(const ValueKey('cover-hero-flight')),
      );
      final radius = shuttle.borderRadius.resolve(TextDirection.ltr);
      expect(radius.bottomLeft, Radius.zero);
      expect(radius.bottomRight, Radius.zero);
      expect(radius.topLeft.x, greaterThan(0), reason: '上两角要跟着列表卡片的顶部圆角收');
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(DetailPage), findsNothing);
    });

    testWidgets('小说详情-接口回来后不替换列表封面（不闪）', (tester) async {
      const preview = NovelItem(
        id: '1',
        title: '剑来',
        cover: 'https://example.com/list.jpg',
        author: '作者',
      );
      final fake = FakePreviewTransport()
        ..detailCoverUrl = 'https://example.com/detail.jpg';
      await pumpPreview(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: fake,
      );
      final backdrop = tester.widget<DetailCoverBackdrop>(
        find.byType(DetailCoverBackdrop),
      );
      expect(
        backdrop.cover,
        preview.cover,
        reason: '详情接口回来不应把封面换成 detail.jpg（会让 Hero 落位后再加载一次）',
      );
      expect(find.byType(NovelCover), findsNothing, reason: '详情页不再单独画小封面');
    });

    testWidgets('封面 Hero 支持 iOS 手势返回（侧滑也能飞回去）', (tester) async {
      final fake = FakePreviewTransport()
        ..bookCoverUrl = 'https://example.com/cover-1.jpg';
      await pumpPreview(tester, const RecommendPage(), transport: fake);
      final listHeroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
      expect(listHeroes, isNotEmpty);
      expect(
        listHeroes.every((hero) => hero.transitionOnUserGestures),
        isTrue,
        reason: '列表封面 Hero 必须支持手势转场，否则 iOS 侧滑返回不飞',
      );

      final card = tester.widget<NovelGridCard>(
        find.byType(NovelGridCard).first,
      );
      await tester.tap(find.byType(NovelGridCard).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final detailHero = tester.widget<Hero>(
        find
            .descendant(
              of: find.byType(DetailPage),
              matching: find.byType(Hero),
            )
            .first,
      );
      expect(detailHero.tag, card.heroTag);
      expect(detailHero.transitionOnUserGestures, isTrue);
    });

    testWidgets('小说详情-加载中不转圈', (tester) async {
      final fake = FakePreviewTransport()
        ..responseDelay = const Duration(milliseconds: 80);
      await pumpPreview(
        tester,
        const DetailPage(bookId: '1'),
        transport: fake,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '详情加载阶段只保留封面背景，不再显示转圈',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('剑来'), findsWidgets);
    });

    testWidgets('小说详情-作者行带状态字数，评分/在读/更新至合并一行', (tester) async {
      const preview = NovelItem(id: '1', title: '剑来', author: '作者');
      await pumpPreview(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: FakePreviewTransport(),
      );

      // 作者 · 状态 · 字数 在同一行；分类不再出现（简介里已有标签）。
      expect(find.text('烽火戏诸侯 · 连载中 · 132.8万字'), findsOneWidget);
      expect(find.textContaining('玄幻 ·'), findsNothing);

      // 评分 / 在读 / 更新至 合并成一行：三者的中线应一致。
      final score = tester.getCenter(find.text('9.3')).dy;
      final readers = tester.getCenter(find.text('1.2万人在读')).dy;
      final updated = tester.getCenter(find.text('更新至 第一千零二十四章 开天')).dy;
      expect(readers, closeTo(score, 0.5));
      expect(updated, closeTo(score, 0.5));
    });

    testWidgets('详情页-封面同时作为顶部背景（顶部不透明到底部透明）', (tester) async {
      const preview = NovelItem(
        id: '1',
        title: '剑来',
        cover: 'https://example.com/list.jpg',
      );
      await pumpPreview(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: FakePreviewTransport(),
      );
      final backdrop = find.byWidgetPredicate(
        (widget) => widget is ShaderMask && widget.blendMode == BlendMode.dstIn,
      );
      expect(backdrop, findsOneWidget, reason: '封面应作为背景并做透明度渐变');
    });
  });

  group('资源 ID 行', () {
    testWidgets('详情页最下方展示书籍 ID，可一键复制', (tester) async {
      // 拦截系统通道，捕获 Clipboard.setData 写入的文本。
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpPreview(tester, const DetailPage(bookId: '1'));
      // 滚到内容最下方：ID 行位于目录之后、底部操作栏之上。
      final footerText = find.text('书籍 ID：1');
      await tester.scrollUntilVisible(
        footerText,
        240,
        scrollable: _verticalScrollable,
      );
      await tester.pumpAndSettle();
      expect(footerText, findsOneWidget);

      await tester.tap(find.byTooltip('复制 ID'));
      await tester.pumpAndSettle();
      expect(copied, '1', reason: '复制的是完整 ID');
      expect(find.text('ID 已复制'), findsOneWidget, reason: '复制后弹浮动 SnackBar');
    });

    testWidgets('详情加载中不先显示 ID 行，数据回来后才出现', (tester) async {
      // 回归：ID 行曾先于简介/目录出现，内容淡入后再被顶下去（视觉跳动）。
      // 现在必须等详情数据回来才渲染，并且和内容一起淡入。
      final fake = FakePreviewTransport()
        ..responseDelay = const Duration(milliseconds: 120);
      await pumpPreview(
        tester,
        const DetailPage(bookId: '1'),
        transport: fake,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        find.byType(DetailIdFooter, skipOffstage: false),
        findsNothing,
        reason: '数据没回来前不应渲染 ID 行（否则会被简介/目录顶下去）',
      );

      // 数据回来 + 淡入完成。ID 行在内容最下方，可能在屏幕外，所以只断言
      // 它已进入部件树（skipOffstage: false）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(DetailIdFooter, skipOffstage: false),
        findsOneWidget,
        reason: '数据回来后 ID 行才出现',
      );
    });
  });

  testWidgets('阅读页加入书架后返回详情，底栏收藏态同步', (tester) async {
    await pumpPreview(tester, const DetailPage(bookId: '1'));
    expect(find.text('收藏'), findsOneWidget);

    // 详情 → 开始阅读 → 阅读页顶部「加入书架」。
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(ReaderPage), findsOneWidget);
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('已在书架'), findsOneWidget);

    // 返回详情：底栏不能还停留在「收藏」（书架数据已写，状态必须刷新）。
    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(DetailPage), findsOneWidget);
    expect(find.text('已收藏'), findsOneWidget);
    expect(find.text('收藏'), findsNothing);
  });

  testWidgets('详情页', (tester) async {
    await pumpPreview(tester, const DetailPage(bookId: '1'));
    await expectLater(
      find.byType(DetailPage),
      matchesGoldenFile('../goldens/detail.png'),
    );
  });
}

/// 详情页外层 CustomScrollView 的纵向滚动；选集 tab 里还有横向 Scrollable。
final Finder _verticalScrollable = find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    )
    .first;
