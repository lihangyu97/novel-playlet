import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/app_image_cache.dart';

/// 评论配图的 [ImageProvider] 工厂。
///
/// 抽成 provider 只为一件事：widget 测试可以覆盖成内存图，不碰网络与磁盘
/// 缓存；生产环境统一走 [AppImageCache]（与封面共用 7 天 / 120 个对象的
/// 缓存），避免评论图在 ImageCache 里被反复解码。
typedef CommentImageLoader = ImageProvider Function(
  String url, {
  int? memCacheWidth,
});

final commentImageLoaderProvider = Provider<CommentImageLoader>((ref) {
  return (url, {memCacheWidth}) => CachedNetworkImageProvider(
    url,
    cacheManager: AppImageCache.manager,
    maxWidth: memCacheWidth,
  );
});
