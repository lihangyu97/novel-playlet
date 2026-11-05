import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/theme/app_theme.dart';
import 'app/theme/theme_settings.dart';
import 'core/cache/app_image_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局竖屏：阅读器是横向分页、列表也是竖屏布局，转横屏只会把布局挤坏。
  // 播放页需要横屏放视频时，自己在进入全屏时临时放开、退出时恢复（见
  // features/video/video_player_page.dart 的 _enterFullscreen/_restorePortrait）。
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  // 封面缓存按体积兜底裁剪：不阻塞启动，失败静默。
  unawaited(AppImageCache.trimOnStart());
  // 主题色在首帧之前读出来：否则自定义过主题色的用户会先看到一下天蓝的
  // Splash 图标再变色。读盘失败/挂起就走默认色，不能因此卡住启动。
  final seed = await _restoreThemeSeed();
  runApp(
    ProviderScope(
      overrides: [
        themeSeedProvider.overrideWith(
          () => ThemeSeedController(initialSeed: seed),
        ),
      ],
      child: const NovelPlayletApp(),
    ),
  );
}

Future<Color> _restoreThemeSeed() async {
  try {
    final prefs = await SharedPreferences.getInstance().timeout(
      const Duration(milliseconds: 300),
    );
    final argb = prefs.getInt(ThemeSeedController.seedKey);
    return argb == null ? appSeedColor : Color(argb);
  } catch (_) {
    // 读不到或超过 300ms 还没返回：按默认色走，别让首帧被磁盘 IO 挡住。
    return appSeedColor;
  }
}
