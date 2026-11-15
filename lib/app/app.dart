import 'package:flutter/material.dart';
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
