import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/features/recommend/recommend_layout.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 设置页预览：主题色（3 个预设 + 自定义）、深浅色模式、首页推荐布局、存储与视频区块。
///
/// 更新基线：`flutter test --update-goldens test/ui/settings_page_test.dart`。
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

  /// 离线下载清晰度：默认 720P，可切换并落盘。
  testWidgets('设置页-离线下载清晰度默认 720P，可切换', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    expect(find.text('离线下载清晰度'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '720P'))
          .selected,
      isTrue,
      reason: '离线下载默认 720P',
    );

    await tester.tap(find.text('1080P'));
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1080P'))
          .selected,
      isTrue,
    );
  });

  testWidgets('设置页-只有三个预设色 + 一个自定义入口', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    expect(themeColorOptions, hasLength(3));
    expect(find.byTooltip('天蓝'), findsOneWidget);
    expect(find.byTooltip('草绿'), findsOneWidget);
    expect(find.byTooltip('绯红'), findsOneWidget);
    expect(find.byTooltip('竹青'), findsNothing, reason: '旧预设色应已删除');
    expect(find.byKey(themeCustomColorKey), findsOneWidget);
  });

  /// 自定义入口点开后，取色弹层初始值必须是当前主题色。
  testWidgets('设置页-自定义色块打开取色弹层，初始为当前主题色', (tester) async {
    SharedPreferences.setMockInitialValues({'app_seed_color_v1': 0xFFEF5350});
    await pumpPreview(tester, const SettingsPage());
    await tester.tap(find.byKey(themeCustomColorKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('自定义主题色'), findsOneWidget);
    expect(find.text('#EF5350'), findsOneWidget, reason: '弹层应回显当前主题色');

    // 取消 / 确定必须是同一套小圆角（M3 默认 Outlined 是 StadiumBorder）。
    BorderRadiusGeometry? radiusOf(ButtonStyle? style) {
      final shape = style?.shape?.resolve(<WidgetState>{});
      return shape is RoundedRectangleBorder ? shape.borderRadius : null;
    }

    final outlined = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '取消'),
    );
    final filled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确定'),
    );
    expect(radiusOf(outlined.style), BorderRadius.circular(12));
    expect(radiusOf(filled.style), BorderRadius.circular(12));

    // 截整个屏幕（含遮罩与背后的设置页），只截 sheet 子树会丢掉上下文。
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/settings_color_picker.png'),
    );
  });

  testWidgets('设置页-存储提示只剩离线缓存一条', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    expect(find.textContaining('离线缓存不在此列'), findsOneWidget);
    expect(find.textContaining('书架与阅读进度不会动'), findsNothing);
  });

  testWidgets('设置页-跟随时隐藏深色模式，关闭跟随后可手动切换', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );

    // 默认跟随系统：深色模式那一行直接隐藏，只剩跟随系统一个开关。
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(find.text('深色模式'), findsNothing);
    expect(find.text('跟随系统'), findsOneWidget);
    final switches = find.byType(Switch);
    expect(switches, findsOneWidget);
    expect(tester.widget<Switch>(switches.at(0)).value, isTrue);

    // 关掉跟随系统：深色模式出现（排在跟随系统上面），当前固定为浅色。
    await tester.tap(switches.at(0));
    await tester.pump();
    expect(container.read(themeModeProvider), ThemeMode.light);
    expect(find.text('深色模式'), findsOneWidget);
    expect(switches, findsNWidgets(2));
    expect(tester.widget<Switch>(switches.at(0)).value, isFalse);
    expect(tester.widget<Switch>(switches.at(1)).value, isFalse);

    // 手动打开深色。
    await tester.tap(switches.at(0));
    await tester.pump();
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(tester.widget<Switch>(switches.at(1)).value, isFalse);

    // 再打开跟随系统：深色模式重新隐藏。
    await tester.tap(switches.at(1));
    await tester.pump();
    expect(container.read(themeModeProvider), ThemeMode.system);
    expect(find.text('深色模式'), findsNothing);
    expect(switches, findsOneWidget);
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

  /// 首页推荐布局：默认双列，可切三列并落盘（推荐页 watch 同一个 provider）。
  testWidgets('设置页-首页推荐布局默认双列，可切三列', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );

    expect(find.text('首页推荐布局'), findsOneWidget);
    expect(container.read(recommendLayoutProvider), RecommendLayout.two);
    expect(
      tester.widget<ChoiceChip>(find.byKey(recommendLayoutTwoKey)).selected,
      isTrue,
    );
    expect(find.text('双列：封面更大，一屏看到的少一点'), findsOneWidget);

    // ListView 懒加载：先滚到选项再点，避免以后上面再加一张卡就点不到。
    await tester.ensureVisible(find.byKey(recommendLayoutThreeKey));
    await tester.tap(find.byKey(recommendLayoutThreeKey));
    await tester.pump();
    expect(container.read(recommendLayoutProvider), RecommendLayout.three);
    expect(
      tester.widget<ChoiceChip>(find.byKey(recommendLayoutThreeKey)).selected,
      isTrue,
    );
    expect(find.text('三列：封面更小，一屏看到的多一点'), findsOneWidget);
    // 落盘由 test/recommend_layout_test.dart 覆盖（页面测试只验证交互与联动）。
  });

  testWidgets('设置页-深色', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      brightness: Brightness.dark,
      extraOverrides: [
        themeModeProvider.overrideWith(
          () => ThemeModeController(initialMode: ThemeMode.dark),
        ),
      ],
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings_dark.png'),
    );
  });
}
