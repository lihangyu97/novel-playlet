import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/theme/app_font_weight.dart';
import 'app/theme/app_theme.dart';
import 'app/theme/theme_settings.dart';
import 'core/cache/app_image_cache.dart';
import 'core/diagnostics/error_handlers.dart';
import 'features/recommend/recommend_layout.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先装全局错误捕获：启动期（内核初始化、读偏好）的未捕获异常也要能落日志。
  installDiagnosticErrorHandlers();
  // 全局竖屏：阅读器是横向分页、列表也是竖屏布局，转横屏只会把布局挤坏。
  // 播放页需要横屏放视频时，自己在进入全屏时临时放开、退出时恢复（见
  // features/video/video_player_page.dart 的 _enterFullscreen/_restorePortrait）。
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  // 封面缓存按体积兜底裁剪：不阻塞启动，失败静默。
  unawaited(AppImageCache.trimOnStart());
  // 主题色、深浅色模式、推荐布局、全局字重都在首帧之前读出来：否则自定义
  // 过主题的用户会先看到一下默认观感再切换，首页也会先按双列渲染再跳三列。
  // 读盘失败/挂起就走默认值，不能因此卡住启动。
  final preferences = await _restorePreferences();
  runApp(
    ProviderScope(
      overrides: [
        themeSeedProvider.overrideWith(
          () => ThemeSeedController(initialSeed: preferences.seed),
        ),
        themeModeProvider.overrideWith(
          () => ThemeModeController(initialMode: preferences.mode),
        ),
        recommendLayoutProvider.overrideWith(
          () => RecommendLayoutController(initialLayout: preferences.layout),
        ),
        appFontWeightProvider.overrideWith(
          () => AppFontWeightController(
            initialFontWeight: preferences.fontWeight,
          ),
        ),
      ],
      child: const NovelPlayletApp(),
    ),
  );
}

/// 一次读盘同时取回主题色、深浅色模式、推荐流布局与全局字重；
/// 读不到/超时都用默认值。
Future<
  ({Color seed, ThemeMode mode, RecommendLayout layout, FontWeight fontWeight})
>
_restorePreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance().timeout(
      const Duration(milliseconds: 300),
    );
    final argb = prefs.getInt(ThemeSeedController.seedKey);
    final modeIndex = prefs.getInt(ThemeModeController.modeKey);
    return (
      seed: argb == null ? appSeedColor : Color(argb),
      mode:
          modeIndex == null ||
              modeIndex < 0 ||
              modeIndex >= ThemeMode.values.length
          ? ThemeMode.system
          : ThemeMode.values[modeIndex],
      layout: recommendLayoutFromIndex(
        prefs.getInt(RecommendLayoutController.layoutKey),
      ),
      fontWeight: appFontWeightFromValue(
        prefs.getInt(AppFontWeightController.fontWeightKey),
      ),
    );
  } catch (_) {
    // 读不到或超过 300ms 还没返回：按默认观感走，别让首帧被磁盘 IO 挡住。
    return (
      seed: appSeedColor,
      mode: ThemeMode.system,
      layout: RecommendLayout.two,
      fontWeight: FontWeight.w400,
    );
  }
}
