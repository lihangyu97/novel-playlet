import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';

/// 封面占位色：上游 `color_dominate` → 封面还没加载出来时的底色。
void main() {
  group('coverPlaceholderColorOf', () {
    test('解析 #RRGGBB（真实样本）', () {
      expect(coverPlaceholderColorOf('#201818'), const Color(0xFF201818));
      expect(coverPlaceholderColorOf('#786858'), const Color(0xFF786858));
    });

    test('兼容大写 / 省略 # / 8 位带 alpha', () {
      expect(coverPlaceholderColorOf('#C8D0D0'), const Color(0xFFC8D0D0));
      expect(coverPlaceholderColorOf('b87850'), const Color(0xFFB87850));
      expect(coverPlaceholderColorOf('#80FF0000'), const Color(0x80FF0000));
    });

    test('空串 / 非法 / 全透明返回 null（退回系统灰）', () {
      expect(coverPlaceholderColorOf(''), isNull);
      expect(coverPlaceholderColorOf('  '), isNull);
      expect(coverPlaceholderColorOf('#12'), isNull);
      expect(coverPlaceholderColorOf('#zzzzzz'), isNull);
      expect(coverPlaceholderColorOf('#00FF0000'), isNull);
    });
  });

  testWidgets('封面还没加载时用 color_dominate 垫底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NovelCover(
            url: '',
            width: 100,
            height: 133,
            placeholderColor: Color(0xFF201818),
          ),
        ),
      ),
    );
    final boxes = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(NovelCover),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(
      boxes.any((box) => box.color == const Color(0xFF201818)),
      isTrue,
      reason: '占位底色应来自上游主色，而不是系统灰',
    );
  });

  testWidgets('没有 color_dominate 时退回主题灰占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const Scaffold(
          body: NovelCover(url: '', width: 100, height: 133),
        ),
      ),
    );
    final theme = ThemeData(useMaterial3: true);
    final boxes = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(NovelCover),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(
      boxes.any(
        (box) => box.color == theme.colorScheme.surfaceContainerHighest,
      ),
      isTrue,
    );
  });
}
