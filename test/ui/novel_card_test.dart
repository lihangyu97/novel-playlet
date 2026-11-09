import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/media_card.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/widgets/surface_card.dart';
import 'package:novel_playlet/data/models/novel_item.dart';

/// 推荐流小说卡片的元信息：书名下方固定显示作者（作者空退回分类），
/// 推荐理由 / 热度（rank_score）各自一行、有就显示；评分不进元信息行，
/// 单独放封面右上角角标。书架等入口保持作者/分类单行。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );

  NovelGridCard card({
    String author = '作者',
    String category = '',
    String score = '',
    String reason = '',
    String rank = '',
    bool enabled = true,
    bool reasonOnCover = false,
  }) {
    return NovelGridCard(
      item: NovelItem(
        id: '1',
        title: '书名',
        author: author,
        category: category,
        score: score,
        recommendReason: reason,
        rankScore: rank,
      ),
      onTap: () {},
      showRecommendMeta: enabled,
      reasonOnCover: reasonOnCover,
    );
  }

  testWidgets('作者无条件显示；推荐理由与热度各自一行（有就显示）', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '巅峰榜No.3', rank: '8479万热度', score: '9.3')),
    );
    expect(find.text('作者'), findsOneWidget, reason: '作者固定显示，不被理由/热度顶掉');
    expect(find.text('巅峰榜No.3'), findsOneWidget);
    expect(find.text('8479万热度'), findsOneWidget);
    expect(find.text('9.3分'), findsOneWidget, reason: '评分显示在角标上');
  });

  group('双列：理由上封面 + 热度右对齐', () {
    testWidgets('推荐理由在封面角标，热度与作者同一行靠右', (tester) async {
      await tester.pumpWidget(
        wrap(
          card(
            reason: '巅峰榜No.3',
            rank: '8479万热度',
            score: '9.3',
            reasonOnCover: true,
          ),
        ),
      );
      expect(find.text('巅峰榜No.3'), findsOneWidget);
      expect(find.text('作者'), findsOneWidget);
      expect(find.text('8479万热度'), findsOneWidget);
      final titleY = tester.getTopLeft(find.text('书名')).dy;
      expect(
        tester.getTopLeft(find.text('巅峰榜No.3')).dy,
        lessThan(titleY),
        reason: '推荐理由在封面角标上，不占文字区',
      );
      final author = tester.getTopLeft(find.text('作者'));
      final heat = tester.getTopLeft(find.text('8479万热度'));
      expect(heat.dy, closeTo(author.dy, 0.5), reason: '热度与作者同一行');
      expect(heat.dx, greaterThan(author.dx), reason: '热度靠右，行尾不空着');
    });

    testWidgets('没有理由/热度时只剩作者一行', (tester) async {
      await tester.pumpWidget(wrap(card(score: '9.3', reasonOnCover: true)));
      expect(find.text('作者'), findsOneWidget);
      expect(find.textContaining('巅峰榜'), findsNothing);
    });
  });

  testWidgets('行序：书名 → 作者 → 推荐理由 → 热度', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '巅峰榜No.3', rank: '8479万热度', score: '9.3')),
    );
    final titleY = tester.getTopLeft(find.text('书名')).dy;
    final authorY = tester.getTopLeft(find.text('作者')).dy;
    final reasonY = tester.getTopLeft(find.text('巅峰榜No.3')).dy;
    final rankY = tester.getTopLeft(find.text('8479万热度')).dy;
    expect(titleY, lessThan(authorY), reason: '作者紧贴书名下方');
    expect(authorY, lessThan(reasonY));
    expect(reasonY, lessThan(rankY));
  });

  testWidgets('只有热度：作者 + 热度两行', (tester) async {
    await tester.pumpWidget(wrap(card(rank: '8479万热度', score: '9.3')));
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('8479万热度'), findsOneWidget);
    expect(find.text('9.3分'), findsOneWidget);
  });

  testWidgets('只有推荐理由：作者 + 理由两行', (tester) async {
    await tester.pumpWidget(wrap(card(reason: '巅峰榜No.3', score: '9.3')));
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('巅峰榜No.3'), findsOneWidget);
  });

  testWidgets('没有理由/热度时只有作者一行；评分只进角标', (tester) async {
    await tester.pumpWidget(wrap(card(score: '9.3')));
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('作者 · 9.3分'), findsNothing, reason: '评分不再混在作者行里');
    expect(find.text('9.3分'), findsOneWidget);
  });

  testWidgets('无评分（空 / 0 / 0.0）：只显示作者、无角标', (tester) async {
    for (final raw in ['', '0', '0.0']) {
      await tester.pumpWidget(wrap(card(score: raw)));
      expect(find.text('作者'), findsOneWidget, reason: 'score=$raw 不应出现评分');
      expect(find.textContaining('分'), findsNothing);
    }
  });

  testWidgets('作者缺失时退回分类；评分只进角标', (tester) async {
    await tester.pumpWidget(
      wrap(card(author: '', category: '玄幻', score: '9.0')),
    );
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('9.0分'), findsOneWidget);
  });

  testWidgets('作者与分类都缺失：元信息行无文案，评分仍只在角标', (tester) async {
    await tester.pumpWidget(wrap(card(author: '', score: '8.8')));
    expect(find.text('8.8分'), findsOneWidget);
  });

  testWidgets('标题只有一行时也占两行高度：同排卡片元信息行对齐', (tester) async {
    NovelGridCard build(String id, String title) => NovelGridCard(
      item: NovelItem(id: id, title: title, author: '作者', score: '9.3'),
      onTap: () {},
      width: 108,
      showRecommendMeta: true,
    );
    await tester.pumpWidget(
      wrap(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [build('1', '短书名'), build('2', '一个明显会折成两行的很长很长的书名')],
        ),
      ),
    );
    final cards = find.byType(NovelGridCard);
    expect(
      tester.getSize(cards.at(0)).height,
      tester.getSize(cards.at(1)).height,
      reason: '一行标题与两行标题的卡片视觉高度必须一致',
    );
    final metas = find.text('作者');
    expect(metas, findsNWidgets(2));
    expect(
      tester.getTopLeft(metas.at(0)).dy,
      tester.getTopLeft(metas.at(1)).dy,
      reason: '两张卡片的元信息行基线要对齐',
    );
  });

  testWidgets('书架等入口不传 showRecommendMeta：保持原元信息、无评分角标', (tester) async {
    await tester.pumpWidget(
      wrap(
        card(reason: '巅峰榜No.3', rank: '8479万热度', score: '9.3', enabled: false),
      ),
    );
    expect(find.text('作者'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
    expect(find.text('巅峰榜No.3'), findsNothing);
    expect(find.text('8479万热度'), findsNothing);
  });

  group('推荐流白底卡片（surface + naturalTitleHeight）', () {
    NovelGridCard feedCard({
      required String id,
      String title = '书名',
      String author = '作者',
    }) {
      return NovelGridCard(
        item: NovelItem(id: id, title: title, author: author, score: '9.3'),
        onTap: () {},
        width: 173,
        showRecommendMeta: true,
        surface: true,
        naturalTitleHeight: true,
        coverAspect: kNovelCoverAspect,
      );
    }

    /// 卡片自己的 Material：AppSurfaceCard 是唯一的卡片底色来源。
    Material surfaceMaterial(WidgetTester tester) {
      return tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppSurfaceCard),
              matching: find.byType(Material),
            )
            .first,
      );
    }

    testWidgets('白底 + 小圆角，封面底部直角（圆角交给卡片裁）', (tester) async {
      await tester.pumpWidget(wrap(feedCard(id: '1')));
      expect(find.byType(AppSurfaceCard), findsOneWidget);
      expect(surfaceMaterial(tester).color, Colors.white);
      expect(
        surfaceMaterial(tester).borderRadius,
        BorderRadius.circular(AppTheme.mediaCardRadius),
      );
      expect(
        AppTheme.mediaCardRadius,
        lessThan(AppTheme.cardRadius),
        reason: '媒体卡圆角比通用 Card 小',
      );
      final cover = tester.widget<NovelCover>(find.byType(NovelCover));
      expect(cover.radius, 0, reason: '封面不自己画圆角：顶部由卡片裁、底部保持直角');
      expect(
        cover.height / cover.width,
        closeTo(kNovelCoverAspect, 0.001),
        reason: '推荐流按内容域原生比例出封面',
      );
    });

    testWidgets('暗色模式：卡片底色用 surfaceContainerHigh，不用纯白', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(child: feedCard(id: '1')),
          ),
        ),
      );
      final dark = AppTheme.dark();
      expect(
        surfaceMaterial(tester).color,
        dark.colorScheme.surfaceContainerHigh,
        reason: '暗色不能硬编码纯白，靠比画布亮一档的底色分层',
      );
    });

    testWidgets('标题按自然高度：一行标题的卡片比两行矮', (tester) async {
      await tester.pumpWidget(
        wrap(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              feedCard(id: '1', title: '短书名'),
              feedCard(id: '2', title: '一个明显会折成两行的很长很长的书名'),
            ],
          ),
        ),
      );
      final heights = tester
          .widgetList<NovelGridCard>(find.byType(NovelGridCard))
          .map((card) => tester.getSize(find.byWidget(card)).height)
          .toList();
      expect(
        heights.first,
        lessThan(heights.last),
        reason: '瀑布流卡片高度由标题行数决定，不再固定两行',
      );
    });

    testWidgets('默认形态（书架等）不画白底卡', (tester) async {
      await tester.pumpWidget(wrap(card(score: '9.3')));
      expect(find.byType(AppSurfaceCard), findsNothing);
      expect(
        tester.widget<NovelCover>(find.byType(NovelCover)).radius,
        kCoverRadius,
        reason: '紧凑网格保持原来的封面圆角，白底卡才由卡片裁圆角',
      );
    });

    testWidgets('元信息为空时不占行，卡片更矮', (tester) async {
      MediaCard mediaCard({String? meta}) => MediaCard(
        cover: '',
        title: '书名',
        meta: meta,
        width: 173,
        onTap: () {},
        surface: true,
        naturalTitleHeight: true,
      );

      await tester.pumpWidget(
        wrap(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mediaCard(meta: null),
              mediaCard(meta: '作者'),
            ],
          ),
        ),
      );
      final heights = tester
          .widgetList<MediaCard>(find.byType(MediaCard))
          .map((card) => tester.getSize(find.byWidget(card)).height)
          .toList();
      expect(heights.first, lessThan(heights.last), reason: '没有元信息的卡片不该留空行');
    });
  });
}
