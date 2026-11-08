import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';

/// 推荐流短剧/漫剧卡片的元信息优先级：推荐理由 → 热度（rec_text）→
/// 「全 N 集 · 评分」；书架等入口保持「全 N 集」。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );

  VideoCard card({
    String reason = '',
    String rank = '',
    String score = '',
    int episodeCount = 40,
    bool enabled = true,
  }) {
    return VideoCard(
      item: VideoSeries(
        id: 'v1',
        title: '剧名',
        episodeCount: episodeCount,
        score: score,
        recommendReason: reason,
        rankScore: rank,
      ),
      width: 108,
      onTap: () {},
      showRecommendMeta: enabled,
    );
  }

  testWidgets('推荐理由优先于热度与评分', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '系列剧·40万人在追', rank: '4691万热度', score: '8.2')),
    );
    expect(find.text('系列剧·40万人在追'), findsOneWidget);
    expect(find.text('4691万热度'), findsNothing);
    expect(find.textContaining('8.2分'), findsNothing);
  });

  testWidgets('没有推荐理由时展示热度（rec_text）', (tester) async {
    await tester.pumpWidget(wrap(card(rank: '4691万热度', score: '8.2')));
    expect(find.text('4691万热度'), findsOneWidget);
  });

  testWidgets('没有理由/热度时退回「全 N 集 · 评分」', (tester) async {
    await tester.pumpWidget(wrap(card(score: '8.2')));
    expect(find.text('全 40 集 · 8.2分'), findsOneWidget);
  });

  testWidgets('没有评分时只显示集数', (tester) async {
    await tester.pumpWidget(wrap(card(score: '0')));
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
  });

  testWidgets('书架等入口不传 showRecommendMeta：保持「全 N 集」', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '系列剧·40万人在追', rank: '4691万热度', enabled: false)),
    );
    expect(find.text('全 40 集'), findsOneWidget);
    expect(find.text('系列剧·40万人在追'), findsNothing);
  });
}
