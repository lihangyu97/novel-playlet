import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'bootstrap_gate.dart';
import 'router.dart';
import 'theme/app_scroll_behavior.dart';
import 'theme/app_theme.dart';

/// 应用根：主题 + 中文本地化 + 路由表。
///
/// 这里不启动任何业务逻辑：内核启动在 [BootstrapGate] 里，保证「先有阅读
/// 环境，再进首页」。
class NovelPlayletApp extends StatelessWidget {
  const NovelPlayletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'novel-playlet',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      scrollBehavior: const AppScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateRoute: AppRoutes.onGenerateRoute,
      home: const BootstrapGate(),
    );
  }
}
