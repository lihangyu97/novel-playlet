import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 设置页预览：主题色切换、深色与自定义颜色弹层。
///
/// 更新基线：`flutter test --update-goldens test/ui/settings_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('设置页', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings.png'),
    );
  });

  /// 离线缓存不再是设置页的入口：只保留「到我的缓存页删除」的提示。
  testWidgets('设置页-不再有离线缓存区块，存储提示指向缓存页', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    expect(find.text('离线小说'), findsNothing);
    expect(find.text('离线短剧'), findsNothing);
    expect(find.textContaining('离线缓存不在这里清理'), findsOneWidget);
    expect(find.textContaining('到「我的」右下角「缓存」页查看和删除'), findsOneWidget);
  });

  testWidgets('设置页-自定义颜色弹层', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    // 截整个屏幕（含遮罩与背后的设置页），只截 sheet 子树会丢掉上下文。
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/settings_color_picker.png'),
    );
  });

  /// 换主题色必须「全站跟着变」：底色/按钮/选中态都由新的 seed 派生。
  testWidgets('设置页-绯红主题', (tester) async {
    SharedPreferences.setMockInitialValues({'app_seed_color_v1': 0xFFEF5350});
    await pumpPreview(tester, const SettingsPage());
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings_theme_red.png'),
    );
  });

  testWidgets('设置页-深色', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings_dark.png'),
    );
  });
}
