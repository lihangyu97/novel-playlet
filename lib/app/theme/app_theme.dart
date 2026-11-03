import 'package:flutter/material.dart';

/// 品牌主色，沿用当前 App 的橙红。
const appSeedColor = Color(0xFFEF5038);

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

/// 全应用设计系统。只在这里定义颜色/字号/圆角，页面不写魔法值。
class AppTheme {
  static const Color accent = appSeedColor;
  static const Color ink = Color(0xFF1B1B1B);
  static const Color subtleInk = Color(0xFF6B6B6B);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color canvas = Color(0xFFF7F7F8);

  static const double cardRadius = 14;

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? canvas
          : scheme.surface,
    );
    return base.copyWith(
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
