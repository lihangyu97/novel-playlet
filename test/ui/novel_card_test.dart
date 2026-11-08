import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/data/models/novel_item.dart';

/// 推荐流小说卡片的元信息行：`作者 · 评分`（点分隔），无评分/0 时不占位。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Center(child: child)),
  );

  NovelGridCard card({
    String author = '作者',
    String category = '',
    String score = '',
  }) {
    return NovelGridCard(
      item: NovelItem(
        id: '1',
        title: '书名',
        author: author,
        category: category,
        score: score,
      ),
      onTap: () {},
      showScore: true,
    );
  }

  testWidgets('作者 + 评分：点分隔，评分带「分」', (tester) async {
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

  testWidgets('书架等入口不传 showScore：保持原元信息', (tester) async {
    await tester.pumpWidget(
      wrap(
        NovelGridCard(
          item: const NovelItem(
            id: '1',
            title: '书名',
            author: '作者',
            score: '9.3',
          ),
          onTap: () {},
        ),
      ),
    );
    expect(find.text('作者'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
  });
}
