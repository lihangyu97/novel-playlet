import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/cache/app_image_cache.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 封面缓存按体积兜底裁剪：不阻塞启动，失败静默。
  unawaited(AppImageCache.trimOnStart());
  runApp(const ProviderScope(child: NovelPlayletApp()));
}
