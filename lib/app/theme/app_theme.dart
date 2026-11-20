import 'package:flutter/material.dart';

/// 默认品牌主色：天蓝。用户没自定义主题色时用它。
///
/// primary/secondary 由它派生（Material 3 seed）；[AppTheme.accent] 这类
/// 「直接要主色」的地方走 [AppTheme.accentOf] 读当前 seed。
const appSeedColor = Color(0xFF4FC3F7);

/// 用户可选的「配色算法」。
///
/// 对应 M3 的 [DynamicSchemeVariant]，只放出规范里稳定的 4 个：
/// `rainbow` / `fruitSalad` 之类是 material_color_utilities 的实验变体，
/// 色相漂移幅度大，给用户选只会显得配色失控。
///
/// 四档只改「每条色板用什么色相、彩度封不封顶」，tone 映射表完全一致，
/// 所以换算法不会破坏对比度。
enum AppThemeVariant {
  standard(
    '标准',
    DynamicSchemeVariant.tonalSpot,
    '柔和统一，Flutter 默认',
  ),
  fidelity(
    '忠实',
    DynamicSchemeVariant.fidelity,
    '保留你挑的颜色本来的鲜艳度',
  ),
  vibrant(
    '鲜艳',
    DynamicSchemeVariant.vibrant,
    '同色相拉到接近最高饱和',
  ),
  expressive(
    '活泼',
    DynamicSchemeVariant.expressive,
    '强调色互相错开，更跳一点',
  );

  const AppThemeVariant(this.label, this.scheme, this.description);

  /// 设置页里的短标签（三字以内，按钮组才排得下）。
  final String label;

  /// 传给 [ColorScheme.fromSeed] 的算法。
  final DynamicSchemeVariant scheme;

  /// 副标题里的一句话说明。
  final String description;
}

/// 从偏好/云端存的 name 还原算法。
///
/// 未知值（旧版本写入、手改过的 settings.json、以后删掉的档位）一律回落
/// [AppThemeVariant.standard]，不让脏数据把主题打挂。
AppThemeVariant appThemeVariantFromName(Object? name) {
  for (final variant in AppThemeVariant.values) {
    if (variant.name == name) return variant;
  }
  return AppThemeVariant.standard;
}

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

/// 全局字重偏移：由「设置 → 全局字重」写入。
///
/// `delta` 是相对标准 400 的档位差（300 = -1，700 = +3）。组件里写死的
/// 强调字重通过 [AppTheme.weightOf] 叠加这个偏移；iOS 恒为 0。
@immutable
class AppFontWeightScale extends ThemeExtension<AppFontWeightScale> {
  const AppFontWeightScale({required this.delta});

  final int delta;

  @override
  AppFontWeightScale copyWith({int? delta}) =>
      AppFontWeightScale(delta: delta ?? this.delta);

  @override
  AppFontWeightScale lerp(ThemeExtension<AppFontWeightScale>? other, double t) {
    if (other is! AppFontWeightScale) return this;
    return t < 0.5 ? this : other;
  }

  @override
  bool operator ==(Object other) =>
      other is AppFontWeightScale && other.delta == delta;

  @override
  int get hashCode => delta.hashCode;
}

/// 便捷写法：`context.appWeight(FontWeight.w600)`。
extension AppFontWeightContext on BuildContext {
  FontWeight appWeight(FontWeight base) => AppTheme.weightOf(this, base);
}

/// 把「用户选的主题色 + 配色算法」原样带进 ThemeData。
///
/// 页面平时不需要它：填色/文字/描边一律用 `Theme.of(context).colorScheme`
/// （M3 已保证对比度）。它只服务「需要原始 seed 再自己派生一套 scheme」的
/// 场景，比如阅读页要按纸色明暗重建主题、取色器要按候选色预览。
@immutable
class AppAccent extends ThemeExtension<AppAccent> {
  const AppAccent({
    required this.seed,
    this.variant = AppThemeVariant.standard,
  });

  /// 当前主题 seed（= 用户选的主题色，默认 [appSeedColor]）。
  final Color seed;

  /// 当前配色算法（设置页可切，默认「标准」）。
  final AppThemeVariant variant;

  @override
  AppAccent copyWith({Color? seed, AppThemeVariant? variant}) => AppAccent(
    seed: seed ?? this.seed,
    variant: variant ?? this.variant,
  );

  @override
  AppAccent lerp(ThemeExtension<AppAccent>? other, double t) {
    if (other is! AppAccent) return this;
    return AppAccent(
      seed: Color.lerp(seed, other.seed, t) ?? seed,
      // 算法是离散档位，没有中间态：过半数直接切到目标那一档，避免动画
      // 期间在主色 seed 和算法之间出现「种子的 60% + 算法的 40%」这种假值。
      variant: t < 0.5 ? variant : other.variant,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppAccent && other.seed == seed && other.variant == variant;

  @override
  int get hashCode => Object.hash(seed, variant);
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

  /// 底部弹层顶部圆角。全应用统一（见 `AppBottomSheet`），不要各处自己写。
  static const double sheetRadius = 20;

  /// 媒体卡片（推荐流封面卡）圆角。
  ///
  /// 比通用 [cardRadius] 小一档：卡片是纯白底、封面满宽出血，14 在双列宽卡上
  /// 会显得又圆又笨重；设置页等通用 Card 保持 [cardRadius]，两者不合并。
  static const double mediaCardRadius = 10;

  /// 媒体卡片底色：浅色纯白（跟 Card 主题一致），暗色用比画布亮一档的
  /// `surfaceContainerHigh`。
  ///
  /// 暗色不画阴影：阴影在深色底上几乎不可见，靠底色差分层更干净；浅色画布
  /// 是 [canvas]，纯白卡片才有「浮起一张卡」的层次。
  static Color mediaCardColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHigh
        : Colors.white;
  }

  static ThemeData light([
    Color seed = appSeedColor,
    FontWeight fontWeight = FontWeight.w400,
    AppThemeVariant variant = AppThemeVariant.standard,
  ]) => _build(seed, Brightness.light, fontWeight, variant);

  static ThemeData dark([
    Color seed = appSeedColor,
    FontWeight fontWeight = FontWeight.w400,
    AppThemeVariant variant = AppThemeVariant.standard,
  ]) => _build(seed, Brightness.dark, fontWeight, variant);

  /// 由 seed + 明暗 + 算法直接得到完整主题，用于「局部预览」（取色器里的
  /// 按钮示例）。
  ///
  /// 注意别用 `Theme.of(context).copyWith(colorScheme: ...)` 造临时主题：
  /// copyWith 会保留外层的 [AppAccent] 扩展，`accentOf` 会读到旧 seed。
  static ThemeData themed(
    Color seed,
    Brightness brightness, [
    FontWeight fontWeight = FontWeight.w400,
    AppThemeVariant variant = AppThemeVariant.standard,
  ]) => _build(seed, brightness, fontWeight, variant);

  /// 当前主题色（用户自定义过就是它，否则默认天蓝）。
  static Color accentOf(BuildContext context) =>
      Theme.of(context).extension<AppAccent>()?.seed ?? appSeedColor;

  /// 当前配色算法（默认「标准」）。
  ///
  /// 和 [accentOf] 一样从 [AppAccent] 取：阅读页/弹层要按纸色明暗重建
  /// scheme 时，必须带上用户选的算法，否则同一个 seed 会在两处派生出不同
  /// 的配色。
  static AppThemeVariant variantOf(BuildContext context) =>
      Theme.of(context).extension<AppAccent>()?.variant ??
      AppThemeVariant.standard;

  /// 给写死的强调字重叠加全局偏移。
  ///
  /// 例：全局选 500 时，`w600` 的小标题实际画成 `w700`，和 `textTheme`
  /// 的基础字重一起变粗；iOS 的偏移恒为 0，保留原样。
  static FontWeight weightOf(BuildContext context, FontWeight base) {
    final delta = Theme.of(context).extension<AppFontWeightScale>()?.delta ?? 0;
    return _shiftWeight(base, delta);
  }

  static FontWeight _shiftWeight(FontWeight base, int delta) {
    final value = (base.value + delta * 100).clamp(100, 900);
    return FontWeight.values.firstWhere((weight) => weight.value == value);
  }

  static TextTheme _shiftTextTheme(TextTheme textTheme, int delta) {
    TextStyle? shift(TextStyle? style) => style?.copyWith(
      fontWeight: _shiftWeight(style.fontWeight ?? FontWeight.w400, delta),
    );
    return TextTheme(
      displayLarge: shift(textTheme.displayLarge),
      displayMedium: shift(textTheme.displayMedium),
      displaySmall: shift(textTheme.displaySmall),
      headlineLarge: shift(textTheme.headlineLarge),
      headlineMedium: shift(textTheme.headlineMedium),
      headlineSmall: shift(textTheme.headlineSmall),
      titleLarge: shift(textTheme.titleLarge),
      titleMedium: shift(textTheme.titleMedium),
      titleSmall: shift(textTheme.titleSmall),
      bodyLarge: shift(textTheme.bodyLarge),
      bodyMedium: shift(textTheme.bodyMedium),
      bodySmall: shift(textTheme.bodySmall),
      labelLarge: shift(textTheme.labelLarge),
      labelMedium: shift(textTheme.labelMedium),
      labelSmall: shift(textTheme.labelSmall),
    );
  }

  /// 由 seed 生成配色方案。App、阅读页弹层、取色器预览都必须走这里，
  /// 否则同一 seed 在不同地方会派生出不同颜色。
  ///
  /// [variant] 是用户选的算法（默认「标准」= tonalSpot）。近中性色
  /// （白/灰/黑）无论选了哪种算法都强制走 [DynamicSchemeVariant.monochrome]：
  /// 其余变体都会固定或抬高彩度、只取 hue，而灰阶的 hue 数值不稳定——纯白
  /// 会变成青色、纯黑会变成粉色，用户会以为选色没生效。
  static ColorScheme schemeFor(
    Color seed,
    Brightness brightness, [
    AppThemeVariant variant = AppThemeVariant.standard,
  ]) {
    final neutral = HSVColor.fromColor(seed).saturation < 0.08;
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: neutral
          ? DynamicSchemeVariant.monochrome
          : variant.scheme,
    );
  }

  static ThemeData _build(
    Color seed,
    Brightness brightness,
    FontWeight fontWeight,
    AppThemeVariant variant,
  ) {
    final scheme = schemeFor(seed, brightness, variant);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? canvas
          : scheme.surface,
    );
    final delta = (fontWeight.value - FontWeight.w400.value) ~/ 100;
    final textTheme = _shiftTextTheme(base.textTheme, delta);
    final primaryTextTheme = _shiftTextTheme(base.primaryTextTheme, delta);
    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      extensions: [
        AppAccent(seed: seed, variant: variant),
        AppFontWeightScale(delta: delta),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: base.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: _shiftWeight(FontWeight.w600, delta),
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
            fontWeight: _shiftWeight(
              states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              delta,
            ),
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
          textStyle: TextStyle(
            fontSize: 15,
            fontWeight: _shiftWeight(FontWeight.w600, delta),
          ),
        ),
      ),
      // OutlinedButton 以前用 M3 默认的 StadiumBorder，和 FilledButton 的 12
      // 圆角并排（取色弹层的「取消 / 确定」）会一大一小；统一成同一套小圆角。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(
            fontSize: 15,
            fontWeight: _shiftWeight(FontWeight.w600, delta),
          ),
        ),
      ),
    );
  }

  /// 阅读器正文文字样式：行高固定倍数，字间距随字号微调。
  static TextStyle readerText({
    required double fontSize,
    required double lineHeight,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
  }) => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    color: color,
    letterSpacing: 0.2,
    fontWeight: fontWeight,
  );
}
