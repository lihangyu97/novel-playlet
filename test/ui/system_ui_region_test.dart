import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/app.dart';

/// 状态栏兜底：没有页面级声明时跟随主题明暗。
///
/// 播放页把状态栏固定成白色后，返回到「我的」这类没有自己声明的页面，
/// 白色图标不能留在浅色背景上——见 `AppSystemUiRegion`。
void main() {
  Future<SystemUiOverlayStyle> pumpAndReadStyle(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) =>
            AppSystemUiRegion(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Text('页面')),
      ),
    );
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    return region.value;
  }

  testWidgets('浅色主题：兜底为深色状态栏图标', (tester) async {
    final style = await pumpAndReadStyle(tester, Brightness.light);
    expect(style.statusBarIconBrightness, Brightness.dark);
    // iOS：statusBarBrightness 语义相反，light = 深色内容。
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.statusBarColor, Colors.transparent);
    // 只兜底状态栏，不动系统导航栏。
    expect(style.systemNavigationBarColor, isNull);
    expect(style.systemNavigationBarIconBrightness, isNull);
  });

  testWidgets('深色主题：兜底为白色状态栏图标', (tester) async {
    final style = await pumpAndReadStyle(tester, Brightness.dark);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
  });
}
