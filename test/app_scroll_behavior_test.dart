import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_scroll_behavior.dart';

void main() {
  /// Android 12+ 的 Material 3 默认会给滚动视图套一层拉伸指示器；本项目
  /// 统一关掉，避免详情页/弹层出现 iOS 上没有的橡皮筋观感。
  testWidgets('AppScrollBehavior 在 Android 下不包 stretch 指示器', (tester) async {
    Future<void> pumpWith(ScrollBehavior behavior) {
      return tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          scrollBehavior: behavior,
          home: Scaffold(
            body: ListView(children: const [SizedBox(height: 2000)]),
          ),
        ),
      );
    }

    await pumpWith(const MaterialScrollBehavior());
    expect(
      find.byType(StretchingOverscrollIndicator),
      findsOneWidget,
      reason: '默认行为应带 Android 拉伸指示器，否则这个回归测试没有意义',
    );

    await pumpWith(const AppScrollBehavior());
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
  });
}
