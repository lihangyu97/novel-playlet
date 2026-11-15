import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/app_version.dart';
import 'package:novel_playlet/app/theme/app_font_weight.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/features/settings/widgets/dialogue_highlight_preview.dart';
import 'package:novel_playlet/features/cache/download_quality.dart';
import 'package:novel_playlet/features/recommend/recommend_layout.dart';
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 设置页预览：主题色（3 个预设 + 自定义）、深浅色模式、推荐流布局、全局字重、
/// 存储区块（占用清理 + 下载清晰度）。
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
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    expect(
      find.byKey(globalFontWeightKey),
      findsNothing,
      reason: 'iOS/macOS 不显示全局字重',
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings.png'),
    );
  });

  testWidgets('设置页-Android 全局字重外观', (tester) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpPreview(tester, const SettingsPage());
      await tester.ensureVisible(find.byKey(globalFontWeightKey));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(SettingsPage),
        matchesGoldenFile('../goldens/settings_android.png'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  });

  testWidgets('设置页-全局字重仅 Android 显示并影响主题', (tester) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpPreview(tester, const SettingsPage());

      expect(find.byKey(globalFontWeightKey), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsPage)),
      );
      expect(container.read(appEffectiveFontWeightProvider), FontWeight.w400);

      await tester.ensureVisible(find.byKey(globalFontWeightKey));
      await tester.pump();
      final rect = tester.getRect(find.byKey(globalFontWeightKey));
      await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
      await tester.pumpAndSettle();

      expect(
        container.read(appEffectiveFontWeightProvider).value,
        greaterThan(400),
      );
      final context = tester.element(find.byType(SettingsPage));
      expect(
        Theme.of(context).extension<AppFontWeightScale>()?.delta,
        greaterThan(0),
      );
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  });

  /// 下载清晰度（已并进「存储」区块）：默认 720P，可切换并落盘。
  testWidgets('设置页-下载清晰度默认 720P，可切换', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );

    expect(find.text('下载清晰度'), findsOneWidget);
    expect(find.text('离线下载清晰度'), findsNothing, reason: '标题精简为「下载清晰度」');
    expect(
      container.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p720,
    );
    expect(_qualitySegments(tester).selected, {
      VideoDownloadQuality.p720,
    }, reason: '离线下载默认 720P');

    await tester.ensureVisible(find.text('1080P'));
    await tester.pump();
    await tester.tap(find.text('1080P'));
    await tester.pump();
    expect(
      container.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p1080,
    );
    expect(_qualitySegments(tester).selected, {VideoDownloadQuality.p1080});
  });

  /// 四档清晰度收在一个按钮组里，不再是一排独立 chip。
  testWidgets('设置页-下载清晰度用 M3 按钮组（SegmentedButton）', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    final segmented = _qualitySegments(tester);
    expect(
      find.byType(ChoiceChip),
      findsNothing,
      reason: '清晰度与双列/三列都换成按钮组，页面上不应再有 ChoiceChip',
    );
    expect(
      segmented.segments.map((segment) => segment.value),
      VideoDownloadQuality.values,
      reason: '四档顺序与枚举一致：最高 / 1080P / 720P / 480P',
    );
    expect(segmented.showSelectedIcon, isFalse, reason: '段内文案短，打勾会撑宽');

    // 不要 M3 默认的描边：整组是一条浅色底轨 + 一个实心选中段。
    final side = segmented.style?.side?.resolve(<WidgetState>{});
    expect(
      side?.style ?? BorderStyle.none,
      BorderStyle.none,
      reason: '按钮组不再画外框和段间竖线',
    );
  });

  /// 两块设置卡都是「标题左 / 按钮组右 / 同一条水平线」的 flex 两端对齐：
  /// 不是标题独占一行、按钮另起一行，也不要求两边各占 50%。
  testWidgets('设置页-标题和按钮组两端对齐、同一行', (tester) async {
    await pumpPreview(tester, const SettingsPage());
    const inset = 32.0; // 卡片 16 外边距 + 16 内边距
    const rightEdge = 390 - inset;

    for (final (title, group) in [
      ('推荐流布局', find.byType(SegmentedButton<RecommendLayout>)),
      ('下载清晰度', find.byType(SegmentedButton<VideoDownloadQuality>)),
    ]) {
      final titleRect = tester.getRect(find.text(title));
      final groupRect = tester.getRect(group);
      expect(
        groupRect.center.dy,
        closeTo(titleRect.center.dy, 2),
        reason: '$title 与按钮组应在同一条水平中线上（同一行）',
      );
      expect(titleRect.left, inset, reason: '$title 贴内容左边界');
      expect(
        groupRect.right,
        closeTo(rightEdge, 0.5),
        reason: '$title 的按钮组贴内容右边界（两端对齐）',
      );
      expect(
        groupRect.left,
        greaterThan(titleRect.right + 8),
        reason: '$title 与按钮组之间留出间隔，不是各占一半',
      );
    }
  });

  testWidgets('设置页-只有三个预设色 + 一个自定义入口', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );

    expect(themeColorOptions, hasLength(3));
    expect(find.byTooltip('天蓝'), findsOneWidget);
    expect(find.byTooltip('草绿'), findsOneWidget);
    expect(find.byTooltip('绯红'), findsOneWidget);
    expect(find.byTooltip('竹青'), findsNothing, reason: '旧预设色应已删除');
    expect(find.byKey(themeCustomColorKey), findsOneWidget);
  });

  /// 自定义入口点开后，取色弹层从上次自定义色起步（没有自定义过用占位紫）。
  testWidgets('设置页-自定义色块打开取色弹层，初始为上次自定义色', (tester) async {
    SharedPreferences.setMockInitialValues({
      'app_seed_color_v1': 0xFFEF5350,
      'app_custom_seed_color_v1': 0xFF7E57C2,
    });
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    await tester.tap(find.byKey(themeCustomColorKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('自定义主题色'), findsOneWidget);
    expect(find.text('#7E57C2'), findsOneWidget, reason: '弹层应回显上次自定义色');

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

  testWidgets('设置页-对话高亮颜色可自定义，示例文本跟随取色', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    final initial = container
        .read(readerSettingsProvider)
        .dialogueHighlightColor;
    expect(initial, ReaderSettings.defaultDialogueHighlightColor);

    await tester.ensureVisible(find.byKey(dialogueHighlightColorKey));
    await tester.tap(find.byKey(dialogueHighlightColorKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('对话高亮样式与颜色'), findsOneWidget);
    expect(
      find.byKey(const Key('dialogue-highlight-preview')),
      findsOneWidget,
      reason: '取色弹层里要有阅读页示例文本',
    );
    expect(find.textContaining('你先别急着走', findRichText: true), findsOneWidget);

    // 在饱和度/明度面板左上角点一下换色，示例会实时跟着变，确定后写回设置。
    final panel = find.byKey(const Key('theme-color-sv-panel'));
    await tester.tapAt(tester.getTopLeft(panel) + const Offset(12, 12));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final picked = container
        .read(readerSettingsProvider)
        .dialogueHighlightColor;
    expect(picked, isNot(initial), reason: '确定后要作用到对话高亮颜色');
  });

  testWidgets('设置页-自定义色圆点显示上次自定义颜色', (tester) async {
    SharedPreferences.setMockInitialValues({
      'app_seed_color_v1': 0xFFEF5350,
      'app_custom_seed_color_v1': 0xFF66BB6A,
    });
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );

    final dot = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(themeCustomColorKey),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(
      (dot.decoration as BoxDecoration).color,
      const Color(0xFF66BB6A),
      reason: '第 4 个圆点要显示自定义色，而不是彩虹盘',
    );
  });

  /// 对话高亮的样式与颜色都收在圆点打开的弹层里：卡片上只有色块，弹层里先挑
  /// 画法再挑颜色，示例正文按当前样式 + 颜色渲染。
  testWidgets('设置页-对话高亮样式与颜色在同一个弹层里', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );

    expect(
      find.byKey(dialogueHighlightStyleKey),
      findsNothing,
      reason: '样式按钮组不再占卡片，只在弹层里出现',
    );

    await tester.ensureVisible(find.byKey(dialogueHighlightColorKey));
    await tester.tap(find.byKey(dialogueHighlightColorKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final group = tester.widget<SegmentedButton<DialogueHighlightStyle>>(
      find.byKey(dialogueHighlightStyleKey),
    );
    expect(
      group.segments.map((segment) => segment.value),
      DialogueHighlightStyle.values,
      reason: '荧光笔 / 下划线 / 波浪线三种画法',
    );
    expect(group.selected, {
      DialogueHighlightStyle.marker,
    }, reason: '默认荧光笔，老用户观感不变');

    await tester.tap(find.text('波浪线'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      container.read(readerSettingsProvider).dialogueHighlightStyle,
      DialogueHighlightStyle.wavy,
      reason: '样式在弹层里点完立即生效',
    );
    expect(
      tester
          .widget<SegmentedButton<DialogueHighlightStyle>>(
            find.byKey(dialogueHighlightStyleKey),
          )
          .selected,
      {DialogueHighlightStyle.wavy},
    );
    expect(
      tester
          .widget<DialogueHighlightPreview>(
            find.byType(DialogueHighlightPreview),
          )
          .style,
      DialogueHighlightStyle.wavy,
      reason: '示例正文跟着画法换（不重开弹层）',
    );

    // 取消只回滚颜色，样式已经落库：再打开时仍是波浪线。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(dialogueHighlightColorKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<SegmentedButton<DialogueHighlightStyle>>(
            find.byKey(dialogueHighlightStyleKey),
          )
          .selected,
      {DialogueHighlightStyle.wavy},
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/settings_dialogue_picker.png'),
    );
  });

  testWidgets('设置页-对话高亮色块无边框且与主题圆点同尺寸', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    final swatch = find.byKey(dialogueHighlightColorKey);
    expect(tester.getSize(swatch), const Size(44, 44));
    final box = tester.widget<Container>(
      find.descendant(of: swatch, matching: find.byType(Container)),
    );
    expect(
      (box.decoration as BoxDecoration?)?.border,
      isNull,
      reason: '对话高亮色块不要边框',
    );
  });

  testWidgets('设置页-区块标题/标签/控件左右边界对齐', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    const inset = 32.0; // 卡片 16 外边距 + 16 内边距

    for (final text in ['主题', '对话高亮', '跟随系统', '推荐流布局', '存储']) {
      expect(
        tester.getTopLeft(find.text(text).first).dx,
        inset,
        reason: '$text 的左边线应对齐卡片内容线',
      );
    }

    // 主题色第一颗圆点的左沿、最后一颗（自定义）圆点的右沿贴住内容边界。
    final firstDot = find.byTooltip('天蓝');
    expect(tester.getRect(firstDot).left, inset);
    expect(
      tester.getRect(find.byKey(themeCustomColorKey)).right,
      390 - inset,
      reason: '自定义圆点右沿应对齐内容右边界',
    );

    // 存储行：图标贴内容左边界、数值贴内容右边界（label 在图标后面）。
    expect(
      tester.getTopLeft(find.byIcon(Icons.smart_display_outlined)).dx,
      inset,
    );
    expect(tester.getRect(find.text('339 MB')).right, 390 - inset);
  });

  testWidgets('设置页-范围说明收在存储卡片最下方', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    final hint = find.text('不包括主动缓存的小说、短剧');
    expect(hint, findsOneWidget);
    expect(
      find.ancestor(of: hint, matching: find.byType(Card)),
      findsOneWidget,
      reason: '说明是卡片内部最后一行，不再单挂在页面下方',
    );
    expect(find.textContaining('离线缓存不在此列'), findsNothing);
    expect(find.textContaining('请到「我的 → 缓存」页清理'), findsNothing);
  });

  /// 清理入口只留图标（与详情页「复制 ID」同款小图标按钮），不再占一整行。
  testWidgets('设置页-清理缓存只留图标按钮', (tester) async {
    await pumpPreview(tester, const SettingsPage());

    final clear = find.byTooltip('清理缓存');
    expect(clear, findsOneWidget);
    expect(find.text('清理缓存'), findsNothing, reason: '按钮不再带文案');
    expect(find.byIcon(Icons.cleaning_services_outlined), findsOneWidget);
    expect(
      tester.getSize(clear),
      const Size(24, 24),
      reason: '与详情页复制 ID 同档的小图标按钮（原来是一整个 44pt 胶囊）',
    );

    // 仍然可点：点开确认框。
    await tester.ensureVisible(clear);
    await tester.pump();
    await tester.tap(clear);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('清理缓存？'), findsOneWidget);
  });

  testWidgets('设置页-跟随时隐藏深色模式，关闭跟随后可手动切换', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
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
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('../goldens/settings_theme_red.png'),
    );
  });

  /// 推荐流布局：默认双列，可切三列并落盘（推荐页 watch 同一个 provider）。
  testWidgets('设置页-推荐流布局默认双列，可切三列', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );

    expect(find.text('推荐流布局'), findsOneWidget);
    expect(container.read(recommendLayoutProvider), RecommendLayout.two);
    final segmented = tester.widget<SegmentedButton<RecommendLayout>>(
      find.byType(SegmentedButton<RecommendLayout>),
    );
    expect(segmented.selected, {RecommendLayout.two});

    // ListView 懒加载：先滚到选项再点，避免以后上面再加一张卡就点不到。
    await tester.ensureVisible(find.byKey(recommendLayoutThreeKey));
    await tester.tap(find.byKey(recommendLayoutThreeKey));
    await tester.pump();
    expect(container.read(recommendLayoutProvider), RecommendLayout.three);
    expect(
      tester
          .widget<SegmentedButton<RecommendLayout>>(
            find.byType(SegmentedButton<RecommendLayout>),
          )
          .selected,
      {RecommendLayout.three},
    );
    expect(find.textContaining('封面更大'), findsNothing, reason: '布局说明提示已去掉');
    // 落盘由 test/recommend_layout_test.dart 覆盖（页面测试只验证交互与联动）。
  });

  /// 标题缩短不改变 Row 的 flex 分配：这里锁住「1.1 倍字体下两个 chip 仍
  /// 在同一行」，避免以后又把选项塞回 Flexible/Wrap 里。
  testWidgets('设置页-推荐流布局在 1.1 倍字体下仍为一行', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.1;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
    );

    final two = tester.getRect(find.byKey(recommendLayoutTwoKey));
    final three = tester.getRect(find.byKey(recommendLayoutThreeKey));
    expect(two.top, three.top, reason: '双列/三列应在同一行');
    expect(two.bottom, three.bottom, reason: '双列/三列应在同一行');
  });

  /// 取色器拖动时每帧都会重建预览：换色只能重画色带，不能重新分页。
  testWidgets('设置页-对话高亮预览换色不重新分页', (tester) async {
    var color = const Color(0xFFFFD54F);
    var width = 320.0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SizedBox(
                  width: width,
                  child: DialogueHighlightPreview(color: color),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final initialBuilds = DialogueHighlightPreview.debugPaginationBuilds;
    expect(initialBuilds, greaterThan(0), reason: '首帧应完成一次分页');

    // 连续换色（模拟拖动）不改变宽度/字型 → 不应重新分页。
    for (final next in const [
      Color(0xFF66BB6A),
      Color(0xFFEF5350),
      Color(0xFF4FC3F7),
      Color(0xFF7E57C2),
    ]) {
      rebuild(() => color = next);
      await tester.pump();
    }
    expect(
      DialogueHighlightPreview.debugPaginationBuilds,
      initialBuilds,
      reason: '颜色变化只重画荧光笔，不能每帧重跑 ReaderPagination.build',
    );

    // 可用宽度变了才需要重新分页。
    rebuild(() => width = 280);
    await tester.pump();
    expect(DialogueHighlightPreview.debugPaginationBuilds, initialBuilds + 1);
  });

  testWidgets('设置页-深色', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
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

  /// 版本脚注：显示构建渠道（Release/Beta）+ 版本号 + 构建号，灰色、居中。
  testWidgets('设置页-底部显示版本号与构建号（灰色、居中）', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        appVersionProvider.overrideWith(
          (ref) async => const AppVersion(name: '1.0.0', build: '15'),
        ),
      ],
    );

    final finder = find.text('Release 1.0.0 (15)');
    await tester.scrollUntilVisible(finder, 300);
    expect(finder, findsOneWidget);

    final text = tester.widget<Text>(finder);
    expect(text.textAlign, TextAlign.center);
    final theme = Theme.of(tester.element(finder));
    expect(text.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(
      find.ancestor(of: finder, matching: find.byType(Center)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: finder, matching: find.byType(SettingsPage)),
      findsOneWidget,
    );
  });
}

/// 「下载清晰度」那一组按钮（M3 SegmentedButton）。
SegmentedButton<VideoDownloadQuality> _qualitySegments(WidgetTester tester) =>
    tester.widget<SegmentedButton<VideoDownloadQuality>>(
      find.byType(SegmentedButton<VideoDownloadQuality>),
    );
