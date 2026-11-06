import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/app.dart';
import 'package:novel_playlet/app/bootstrap_gate.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/core/cache/app_cache.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:novel_playlet/features/settings/settings_providers.dart';
import 'package:novel_playlet/features/settings/widgets/theme_color_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存版缓存：settings 页测试不碰真实沙盒目录。
///
/// [clear] 会把占用清成 0，方便断言「清理后页面真的刷新了」，而不是只断言
/// 调用了 clear。
class _FakeAppCache extends AppCache {
  _FakeAppCache({this._usage = const CacheUsage()})
    : super(
        supportDirectory: _unsupportedDirectory,
        temporaryDirectory: _unsupportedDirectory,
        documentsDirectory: _unsupportedDirectory,
        clearImageCache: () async {},
      );

  CacheUsage _usage;
  int measureCount = 0;
  int clearCount = 0;

  /// clear 抛错：验证按钮不会永远卡在「清理中…」。
  bool throwOnClear = false;

  /// clear 挂起：验证清理期间按钮禁用。
  Completer<void>? clearGate;

  @override
  Future<CacheUsage> measure() async {
    measureCount++;
    return _usage;
  }

  @override
  Future<int> clear() async {
    clearCount++;
    if (clearGate != null) await clearGate!.future;
    if (throwOnClear) throw StateError('fake disk failure');
    final freed = _usage.total;
    _usage = const CacheUsage();
    return freed;
  }

  static Future<Directory> _unsupportedDirectory() async =>
      throw UnsupportedError('设置页测试不应访问磁盘');
}

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );
}

final _hexFinder = find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data != null &&
      RegExp(r'^#[0-9A-F]{6}$').hasMatch(widget.data!),
);

/// WCAG 对比度：正文小字要求 ≥ 4.5。
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认主题色就是天蓝', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(themeSeedProvider), appSeedColor);
  });

  test('主题色落盘，新容器能从偏好恢复', () async {
    const picked = Color(0xFFEF5350);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeSeedProvider.notifier).setSeed(picked);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(ThemeSeedController.seedKey), picked.toARGB32());

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(themeSeedProvider), appSeedColor, reason: '首帧先用默认色');
    await pumpEventQueue();
    expect(restored.read(themeSeedProvider), picked);
  });

  test('启动时预读的主题色首帧就生效，且不再异步改回', () async {
    // 模拟 main() 的预读：初始值直接给控制器，内部不再自己读盘。
    SharedPreferences.setMockInitialValues({
      'app_seed_color_v1': const Color(0xFFEF5350).toARGB32(),
    });
    const preloaded = Color(0xFF5C6BC0);
    final container = ProviderContainer(
      overrides: [
        themeSeedProvider.overrideWith(
          () => ThemeSeedController(initialSeed: preloaded),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(themeSeedProvider), preloaded);
    await pumpEventQueue();
    expect(
      container.read(themeSeedProvider),
      preloaded,
      reason: '预读后不应再被磁盘值覆盖',
    );
  });

  test('恢复默认会把偏好写回天蓝', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeSeedProvider.notifier).setSeed(const Color(0xFFAB47BC));
    await pumpEventQueue();
    container.read(themeSeedProvider.notifier).reset();
    await pumpEventQueue();

    expect(container.read(themeSeedProvider), appSeedColor);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('app_seed_color_v1'), appSeedColor.toARGB32());
  });

  test('主题色注入 ThemeData 的 AppAccent，accentOf 读得到', () {
    const picked = Color(0xFF66BB6A);
    final theme = AppTheme.light(picked);
    expect(theme.extension<AppAccent>()?.seed, picked);
    expect(AppTheme.light().extension<AppAccent>()?.seed, appSeedColor);
  });

  /// 近中性 seed 必须走单色变体：M3 默认 tonalSpot 会把纯白映射成青色、
  /// 纯黑映射成粉色，用户会以为选色没生效。
  test('白/灰/黑主题色派生出来的主色仍是中性色', () {
    for (final seed in const [
      Color(0xFFFFFFFF),
      Color(0xFFFAFAFA),
      Color(0xFF808080),
      Color(0xFF000000),
    ]) {
      for (final brightness in Brightness.values) {
        final primary = AppTheme.schemeFor(seed, brightness).primary;
        final saturation = HSVColor.fromColor(primary).saturation;
        expect(
          saturation,
          lessThan(0.1),
          reason:
              'seed=${seed.toARGB32().toRadixString(16)} $brightness '
              '的主色仍有色相（s=$saturation），中性色被染成了彩色',
        );
      }
    }
  });

  /// 阅读弹层现在用「纸色对应的 scheme.primary」做选中文字/填充色，
  /// 这里把「对比度够」钉死：任何主题色 × 任何纸色组合都要 ≥ 4.5:1。
  test('阅读弹层主色与各阅读纸色的对比度 ≥ 4.5', () {
    for (final seed in const [
      appSeedColor,
      Color(0xFFEF5350),
      Color(0xFF66BB6A),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
    ]) {
      for (final paper in ReaderPaper.values) {
        final brightness = paper == ReaderPaper.night
            ? Brightness.dark
            : Brightness.light;
        final primary = AppTheme.schemeFor(seed, brightness).primary;
        final ratio = _contrastRatio(primary, paper.background);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'seed=${seed.toARGB32().toRadixString(16)} paper=${paper.name} '
              '对比度只有 ${ratio.toStringAsFixed(2)}:1',
        );
      }
    }
  });

  /// 根组件接线：之前只测了「页面里的 provider 变了」，即使 app.dart 不看
  /// themeSeedProvider 也能过。这里直接 pump 真实的 NovelPlayletApp。
  ///
  /// 启动闸门停在 loading（不真的起 Rust / 网络页面）：只需要验证 MaterialApp
  /// 跟着 provider 重建，避免把推荐流的定时器/错误带进测试。
  testWidgets('根组件 MaterialApp 跟着主题色重建', (tester) async {
    final never = Completer<void>();
    final container = ProviderContainer(
      overrides: [bootstrapProvider.overrideWith((ref) => never.future)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const NovelPlayletApp(),
      ),
    );
    await tester.pump();

    final gateContext = tester.element(find.byType(BootstrapGate));
    expect(AppTheme.accentOf(gateContext), appSeedColor);

    const picked = Color(0xFFEF5350);
    container.read(themeSeedProvider.notifier).setSeed(picked);
    // MaterialApp 用 AnimatedTheme 过渡主题（默认 200ms），等它跑完再断言终值。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final context = tester.element(find.byType(BootstrapGate));
    expect(AppTheme.accentOf(context), picked);
    // primary 也必须是新 seed 派生的（不是只看扩展字段）。
    expect(
      Theme.of(context).colorScheme.primary,
      AppTheme.schemeFor(picked, Brightness.light).primary,
    );
  });

  testWidgets('设置页-点预设色会切换主题色', (tester) async {
    final cache = _FakeAppCache();
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(cache)],
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    await tester.tap(find.byTooltip('绯红'));
    await tester.pumpAndSettle();

    expect(
      container.read(themeSeedProvider),
      themeColorOptions.firstWhere((option) => option.name == '绯红').color,
    );
  });

  testWidgets('取色弹层-纵向拖动改变明度（不被 bottom sheet 抢走）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(_FakeAppCache())],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeColorPickerSheet), findsOneWidget);
    expect(_hexFinder, findsOneWidget);
    final before = tester.widget<Text>(_hexFinder).data!;

    await tester.drag(
      find.byKey(const Key('theme-color-sv-panel')),
      const Offset(0, -70),
    );
    await tester.pumpAndSettle();

    final after = tester.widget<Text>(_hexFinder).data!;
    expect(after, isNot(before), reason: '纵向拖动必须改变明度，而不是拖动弹层');
    expect(
      find.byType(ThemeColorPickerSheet),
      findsOneWidget,
      reason: '弹层不应被拖走',
    );
  });

  testWidgets('取色弹层-色相拖动生效', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(_FakeAppCache())],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle();

    final before = tester.widget<Text>(_hexFinder).data!;
    await tester.drag(
      find.byKey(const Key('theme-color-hue-bar')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_hexFinder).data!, isNot(before));
  });

  testWidgets('清理缓存需要确认，清理后占用归零、按钮禁用', (tester) async {
    final cache = _FakeAppCache(
      usage: const CacheUsage(video: 10 * 1024 * 1024, image: 2 * 1024 * 1024),
    );
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(cache)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('12 MB'), findsOneWidget);
    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    expect(find.text('清理缓存？'), findsOneWidget);

    // 先取消：不能有任何清理动作。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(cache.clearCount, 0);

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();

    expect(cache.clearCount, 1);
    expect(find.textContaining('已清理 12 MB 缓存'), findsOneWidget);
    // 清理后重新统计，页面上的占用必须真的变成 0。
    expect(find.textContaining('共 0 B'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清理缓存'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('清理失败不会卡在「清理中…」', (tester) async {
    final cache = _FakeAppCache(usage: const CacheUsage(video: 1024 * 1024))
      ..throwOnClear = true;
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(cache)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();

    expect(find.text('清理失败，请重试'), findsOneWidget);
    expect(find.text('清理缓存'), findsOneWidget, reason: '失败后按钮要恢复可点');
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清理缓存'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('清理进行中按钮禁用（不会并发清理）', (tester) async {
    final gate = Completer<void>();
    final cache = _FakeAppCache(usage: const CacheUsage(video: 1024 * 1024))
      ..clearGate = gate;
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(cache)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await tester.pump();

    expect(find.text('清理中…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清理中…'),
    );
    expect(button.onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('清理缓存'), findsOneWidget);
  });

  testWidgets('无缓存时清理按钮禁用', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsPage(),
        overrides: [appCacheProvider.overrideWithValue(_FakeAppCache())],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 B'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清理缓存'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('我的页右上角入口能打开设置页', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const Scaffold(body: MinePage()),
        overrides: [appCacheProvider.overrideWithValue(_FakeAppCache())],
      ),
    );
    await tester.pumpAndSettle();

    // 小说/短剧共用同一枚设置按钮（不再每个面板各画一个）。
    final settings = find.byIcon(Icons.settings_outlined);
    expect(settings, findsOneWidget);
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('设置'), findsWidgets);
  });

  /// 短剧是镜像面板：同一枚设置按钮滑到左侧，点它打开的仍是同一个设置页。
  testWidgets('我的页-短剧左侧设置按钮也能打开设置页', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const Scaffold(body: MinePage()),
        overrides: [appCacheProvider.overrideWithValue(_FakeAppCache())],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    final dramaSettings = find.byIcon(Icons.settings_outlined);
    expect(dramaSettings, findsOneWidget);
    await tester.tap(dramaSettings);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
  });
}
