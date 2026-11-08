import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/data/models/novel_item.dart';

/// 推荐流小说卡片的元信息优先级：推荐理由 → 热度（rank_score）→
/// 「作者 · 评分」；书架等入口保持作者/分类。
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
    );
  }

  testWidgets('推荐理由优先于热度与评分', (tester) async {
    await tester.pumpWidget(
      wrap(card(reason: '巅峰榜No.3', rank: '8479万热度', score: '9.3')),
    );
    expect(find.text('巅峰榜No.3'), findsOneWidget);
    expect(find.text('8479万热度'), findsNothing);
    expect(find.textContaining('9.3分'), findsNothing);
  });

  testWidgets('没有推荐理由时展示热度', (tester) async {
    await tester.pumpWidget(wrap(card(rank: '8479万热度', score: '9.3')));
    expect(find.text('8479万热度'), findsOneWidget);
  });

  testWidgets('没有理由/热度时展示「作者 · 评分」', (tester) async {
    await tester.pumpWidget(wrap(card(score: '9.3')));
    expect(find.text('作者 · 9.3分'), findsOneWidget);
  });

  testWidgets('无评分（空 / 0 / 0.0）：只显示作者', (tester) async {
    for (final raw in ['', '0', '0.0']) {
      await tester.pumpWidget(wrap(card(score: raw)));
      expect(find.text('作者'), findsOneWidget, reason: 'score=$raw 不应出现评分');
      expect(find.textContaining('分'), findsNothing);
    }
  });

  testWidgets('作者缺失：评分单独占元信息行', (tester) async {
    await tester.pumpWidget(wrap(card(author: '', score: '8.8')));
    expect(find.text('8.8分'), findsOneWidget);
  });

  testWidgets('作者缺失时退回分类，再接评分', (tester) async {
    await tester.pumpWidget(
      wrap(card(author: '', category: '玄幻', score: '9.0')),
    );
    expect(find.text('玄幻 · 9.0分'), findsOneWidget);
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
    final metas = find.text('作者 · 9.3分');
    expect(metas, findsNWidgets(2));
    expect(
      tester.getTopLeft(metas.at(0)).dy,
      tester.getTopLeft(metas.at(1)).dy,
      reason: '两张卡片的元信息行基线要对齐',
    );
  });

  testWidgets('书架等入口不传 showRecommendMeta：保持原元信息', (tester) async {
    await tester.pumpWidget(
      wrap(
        card(reason: '巅峰榜No.3', rank: '8479万热度', score: '9.3', enabled: false),
      ),
    );
    expect(find.text('作者'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
    expect(find.text('巅峰榜No.3'), findsNothing);
  });
}
