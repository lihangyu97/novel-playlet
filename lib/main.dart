import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/cache/app_image_cache.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局竖屏：阅读器是横向分页、列表也是竖屏布局，转横屏只会把布局挤坏。
  // 播放页需要横屏放视频时，自己在进入全屏时临时放开、退出时恢复（见
  // features/video/video_player_page.dart 的 _enterFullscreen/_restorePortrait）。
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  // 封面缓存按体积兜底裁剪：不阻塞启动，失败静默。
  unawaited(AppImageCache.trimOnStart());
  runApp(const ProviderScope(child: NovelPlayletApp()));
}
