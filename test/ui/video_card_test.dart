import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/widgets/season_badge.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';

/// 推荐流短剧/漫剧卡片的元信息：书名下方固定显示「全 N 集」，推荐理由 /
/// 热度（rec_text）各自一行、有就显示；评分独立放封面右上角角标。
/// 书架等入口只有「全 N 集」。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );

  VideoCard card({
    String title = '剧名',
    String reason = '',
    String rank = '',
    String score = '',
    int episodeCount = 40,
    bool enabled = true,
    bool reasonOnCover = false,
  }) {
    return VideoCard(
      item: VideoSeries(
        id: 'v1',
        title: title,
        episodeCount: episodeCount,
        score: score,
        recommendReason: reason,
        rankScore: rank,
      ),
      width: 108,
      onTap: () {},
      showRecommendMeta: enabled,
      reasonOnCover: reasonOnCover,
    );
  }

  testWidgets('集数固定一行；推荐理由与热度各自一行（有就显示）', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '系列剧·40万人在追', rank: '4691万热度', score: '8.2')),
    );
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('系列剧·40万人在追'), findsOneWidget);
    expect(find.text('4691万热度'), findsOneWidget);
    expect(find.text('8.2分'), findsOneWidget, reason: '评分在封面角标');
  });

  testWidgets('双列：理由上封面，热度与集数同一行靠右', (tester) async {
    await tester.pumpWidget(
      wrap(
        card(
          reason: '系列剧·40万人在追',
          rank: '4691万热度',
          score: '8.2',
          reasonOnCover: true,
        ),
      ),
    );
    expect(find.text('系列剧·40万人在追'), findsOneWidget);
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('4691万热度'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('系列剧·40万人在追')).dy,
      lessThan(tester.getTopLeft(find.text('剧名')).dy),
      reason: '推荐理由在封面角标上',
    );
    final episodes = tester.getTopLeft(find.text('全 40 集'));
    final heat = tester.getTopLeft(find.text('4691万热度'));
    expect(heat.dy, closeTo(episodes.dy, 0.5), reason: '热度与集数同一行');
    expect(heat.dx, greaterThan(episodes.dx), reason: '热度靠右');
  });

  testWidgets('只有热度：集数 + 热度（rec_text）', (tester) async {
    await tester.pumpWidget(wrap(card(rank: '4691万热度', score: '8.2')));
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('4691万热度'), findsOneWidget);
    expect(find.text('8.2分'), findsOneWidget);
  });

  testWidgets('只有推荐理由：集数 + 理由', (tester) async {
    await tester.pumpWidget(wrap(card(reason: '系列剧·40万人在追')));
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('系列剧·40万人在追'), findsOneWidget);
  });

  testWidgets('没有理由/热度时只显示集数；评分只进角标', (tester) async {
    await tester.pumpWidget(wrap(card(score: '8.2')));
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('全 40 集 · 8.2分'), findsNothing);
    expect(find.text('8.2分'), findsOneWidget);
  });

  testWidgets('没有评分时只显示集数、无角标', (tester) async {
    await tester.pumpWidget(wrap(card(score: '0')));
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
  });

  testWidgets('书架等入口不传 showRecommendMeta：只有「全 N 集」', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '系列剧·40万人在追', rank: '4691万热度', enabled: false)),
    );
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('系列剧·40万人在追'), findsNothing);
    expect(find.text('8.2分'), findsNothing, reason: '书架等入口不显示评分角标');
  });
  testWidgets('标题里有「第 N 季」：封面左下角标出季，标题保持原样', (tester) async {
    await tester.pumpWidget(
      wrap(card(title: '反差大佬：我家小师妹超正经第七季', score: '8.2')),
    );
    expect(find.text('第7季'), findsOneWidget);
    // 位置：封面左下角（距左 6、距底 6），不占用左上理由位和右上评分位。
    final cover = tester.getRect(find.byType(NovelCover));
    final badge = tester.getRect(find.byType(SeasonBadge));
    expect(badge.left, closeTo(cover.left + 6, 0.5));
    expect(badge.bottom, closeTo(cover.bottom - 6, 0.5));
    // 角标不替代标题：标题仍是上游原文（季被两行省略是卡片自身的事）。
    expect(find.text('反差大佬：我家小师妹超正经第七季'), findsOneWidget);
    expect(find.text('8.2分'), findsOneWidget);
  });

  testWidgets('季角标与推荐理由、评分同时出现时互不遮挡', (tester) async {
    await tester.pumpWidget(
      wrap(
        card(
          title: '某剧第五季：副标题',
          reason: '上新',
          score: '8.2',
          reasonOnCover: true,
        ),
      ),
    );
    final season = tester.getRect(find.text('第5季'));
    final reason = tester.getRect(find.text('上新'));
    final score = tester.getRect(find.text('8.2分'));
    expect(season.top, greaterThan(reason.bottom));
    expect(season.top, greaterThan(score.bottom));
  });

  testWidgets('标题没有季标记：不显示季角标', (tester) async {
    await tester.pumpWidget(wrap(card(title: '逾矩', score: '8.2')));
    expect(find.textContaining('季'), findsNothing);
  });
}
