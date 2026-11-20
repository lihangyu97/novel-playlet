import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bootstrap_gate.dart';
import 'theme/app_font_weight.dart';
import 'theme/app_scroll_behavior.dart';
import 'theme/app_theme.dart';
import 'theme/theme_settings.dart';

/// 应用根：主题 + 中文本地化。
///
/// 这里不启动任何业务逻辑：内核启动在 [BootstrapGate] 里，保证「先有阅读
/// 环境，再进首页」。
///
/// 主题色跟着 [themeSeedProvider]：设置页换色后，MaterialApp 直接重建，
/// 全站（含阅读页/弹层）一起变色，不需要重启。
class NovelPlayletApp extends ConsumerWidget {
  const NovelPlayletApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final themeMode = ref.watch(themeModeProvider);
    // iOS 的 effective 值恒为 400，所以这里直接传也不会改变 iOS 观感；
    // Android 才真正跟着设置里的全局字重走。
    final fontWeight = ref.watch(appEffectiveFontWeightProvider);
    return MaterialApp(
      title: 'novel-playlet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(seed, fontWeight),
      darkTheme: AppTheme.dark(seed, fontWeight),
      themeMode: themeMode,
      scrollBehavior: const AppScrollBehavior(),
      // 状态栏兜底：没有页面级声明的页面（我的 / 推荐 / 设置等）跟随主题
      // 明暗。详见 [AppSystemUiRegion]。
      builder: (context, child) =>
          AppSystemUiRegion(child: child ?? const SizedBox.shrink()),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const BootstrapGate(),
    );
  }
}

/// 没有页面级状态栏声明时的兜底：跟随主题明暗。
///
/// 框架只在图层树里找到 `AnnotatedRegion<SystemUiOverlayStyle>` 时才更新
/// 状态栏样式，找不到就沿用上一页的。播放页把状态栏固定成白色后，若返回到
/// 「我的」这类没有自己声明的页面，白色图标会留在浅色背景上直接看不见。
/// 这层兜底挂在 Navigator 外面，详情页 / 阅读页 / 播放页自己的声明仍会
/// 优先命中（图层树里离状态栏更近、更靠上）。只声明状态栏（透明底 + 图标
/// 明暗），系统导航栏维持原样。
class AppSystemUiRegion extends StatelessWidget {
  const AppSystemUiRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 只管状态栏，不碰系统导航栏：阅读页会自己设导航栏底色，Android 15+
      // 的导航栏颜色也已由系统接管，这里不该覆盖。
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: child,
    );
  }
}
