import 'package:flutter/material.dart';

/// 默认品牌主色：天蓝。用户没自定义主题色时用它。
///
/// primary/secondary 由它派生（Material 3 seed）；[AppTheme.accent] 这类
/// 「直接要主色」的地方走 [AppTheme.accentOf] 读当前 seed。
const appSeedColor = Color(0xFF4FC3F7);

/// 阅读页底色（影响状态栏与翻页容器，不影响全局主题）。
enum ReaderPaper {
  white('白', Color(0xFFFFFFFF), Color(0xFF1B1B1B)),
  parchment('纸', Color(0xFFF5EFE0), Color(0xFF2B2620)),
  green('护眼', Color(0xFFE3EDE3), Color(0xFF1F2A22)),
  night('夜间', Color(0xFF121212), Color(0xFFB9B9B9));

  const ReaderPaper(this.label, this.background, this.foreground);

  final String label;
  final Color background;
  final Color foreground;
}

/// 把「用户选的主题色」原样带进 ThemeData。
///
/// 页面平时不需要它：填色/文字/描边一律用 `Theme.of(context).colorScheme`
/// （M3 已保证对比度）。它只服务「需要原始 seed 再自己派生一套 scheme」的
/// 场景，比如阅读页要按纸色明暗重建主题、取色器要按候选色预览。
@immutable
class AppAccent extends ThemeExtension<AppAccent> {
  const AppAccent({required this.seed});

  /// 当前主题 seed（= 用户选的主题色，默认 [appSeedColor]）。
  final Color seed;

  @override
  AppAccent copyWith({Color? seed}) => AppAccent(seed: seed ?? this.seed);

  @override
  AppAccent lerp(ThemeExtension<AppAccent>? other, double t) {
    if (other is! AppAccent) return this;
    return AppAccent(seed: Color.lerp(seed, other.seed, t) ?? seed);
  }

  @override
  bool operator ==(Object other) => other is AppAccent && other.seed == seed;

  @override
  int get hashCode => seed.hashCode;
}

/// 全应用设计系统。只在这里定义颜色/字号/圆角，页面不写魔法值。
class AppTheme {
  /// 默认主色常量（兼容保留）。页面颜色请从 `Theme.of(context).colorScheme`
  /// 取；只有要拿原始 seed 派生 scheme 时才用 [accentOf] + [schemeFor]。
  static const Color accent = appSeedColor;
  static const Color ink = Color(0xFF1B1B1B);
  static const Color subtleInk = Color(0xFF6B6B6B);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color canvas = Color(0xFFF7F7F8);

  static const double cardRadius = 14;

  static ThemeData light([Color seed = appSeedColor]) =>
      _build(seed, Brightness.light);

  static ThemeData dark([Color seed = appSeedColor]) =>
      _build(seed, Brightness.dark);

  /// 由 seed + 明暗直接得到完整主题，用于「局部预览」（取色器里的按钮示例）。
  ///
  /// 注意别用 `Theme.of(context).copyWith(colorScheme: ...)` 造临时主题：
  /// copyWith 会保留外层的 [AppAccent] 扩展，`accentOf` 会读到旧 seed。
  static ThemeData themed(Color seed, Brightness brightness) =>
      _build(seed, brightness);

  /// 当前主题色（用户自定义过就是它，否则默认天蓝）。
  static Color accentOf(BuildContext context) =>
      Theme.of(context).extension<AppAccent>()?.seed ?? appSeedColor;

  /// 由 seed 生成配色方案。App、阅读页弹层、取色器预览都必须走这里，
  /// 否则同一 seed 在不同地方会派生出不同颜色。
  ///
  /// 近中性色（白/灰/黑）要换成 [DynamicSchemeVariant.monochrome]：M3 默认的
  /// tonalSpot 会固定 chroma、只取 hue，灰阶的 hue 数值不稳定——纯白会变成
  /// 青色、纯黑会变成粉色，用户会以为选色没生效。
  static ColorScheme schemeFor(Color seed, Brightness brightness) {
    final neutral = HSVColor.fromColor(seed).saturation < 0.08;
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: neutral
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
    );
  }

  static ThemeData _build(Color seed, Brightness brightness) {
    final scheme = schemeFor(seed, brightness);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? canvas
          : scheme.surface,
    );
    return base.copyWith(
      extensions: [AppAccent(seed: seed)],
      appBarTheme: AppBarTheme(
        backgroundColor: base.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: base.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: brightness == Brightness.light
            ? Colors.white
            : scheme.surfaceContainerHigh,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 0.5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// 阅读器正文文字样式：行高固定倍数，字间距随字号微调。
  static TextStyle readerText({
    required double fontSize,
    required double lineHeight,
    required Color color,
  }) => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    color: color,
    letterSpacing: 0.2,
    fontWeight: FontWeight.w400,
  );
}
