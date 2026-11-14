import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/detail_circle_button.dart';

/// 详情页底部圆形按钮的状态配色。
void main() {
  Future<Color> pumpAndReadBackground(
    WidgetTester tester, {
    required bool active,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: DetailCircleButton(
              icon: Icons.bookmark_added_outlined,
              semanticLabel: '已收藏',
              active: active,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(DetailCircleButton),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return (box.decoration as BoxDecoration).color!;
  }

  testWidgets('已收藏 / 已缓存态：底色不透明，不再透出正文', (tester) async {
    final active = await pumpAndReadBackground(tester, active: true);
    expect(active.a, 1.0, reason: '有状态按钮必须是实色底');

    final idle = await pumpAndReadBackground(tester, active: false);
    expect(idle.a, 1.0, reason: '常态按钮也应是实色底');
  });
}
