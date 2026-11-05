import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/app_cache.dart';

/// 设置页用的缓存实现。生产环境是单例；测试里覆盖成内存假实现，
/// 避免 widget 测试真的去读沙盒目录。
final appCacheProvider = Provider<AppCache>((ref) => AppCache.instance);

/// 缓存占用快照。
///
/// 用 autoDispose：每次打开设置页都重新统计一次，离开页面就丢掉——
/// 视频缓存只有播放时才会长，留着旧数字反而误导用户。
final cacheUsageProvider = FutureProvider.autoDispose<CacheUsage>(
  (ref) => ref.watch(appCacheProvider).measure(),
);
