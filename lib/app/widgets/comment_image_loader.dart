import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/app_image_cache.dart';

/// 评论配图的 [ImageProvider] 工厂。
///
/// 抽成 provider 只为一件事：widget 测试可以覆盖成内存图，不碰网络与磁盘
/// 缓存；生产环境统一走 [AppImageCache]（与封面共用 7 天 / 120 个对象的
/// 缓存，评论图量大了再拆独立 cacheKey，见该类的说明）。
///
/// 解码尺寸必须用 [ResizeImage] 包一层：`CachedNetworkImageProvider.maxWidth`
/// 只在 CacheManager 带 `ImageCacheManager` mixin 时才生效（普通 CacheManager
/// 下 release 会静默忽略、debug 直接断言），而这里共用的是普通
/// [AppImageCache.manager]。包成 ResizeImage 后按格位物理像素解码，几十 pt
/// 的缩略图位不会再解一张原图进 ImageCache。
typedef CommentImageLoader = ImageProvider Function(
  String url, {
  int? memCacheWidth,
});

/// 组装生产用的 provider（纯函数，便于单测）。
///
/// [cacheManager] 为 null 时不碰任何 CacheManager 静态实例：单元测试只验证
/// 「解码尺寸包了 ResizeImage」，不需要 path_provider 插件的目录。
@visibleForTesting
ImageProvider buildCommentImageProvider(
  String url, {
  int? memCacheWidth,
  BaseCacheManager? cacheManager,
}) {
  return ResizeImage.resizeIfNeeded(
    memCacheWidth,
    null,
    CachedNetworkImageProvider(url, cacheManager: cacheManager),
  );
}

final commentImageLoaderProvider = Provider<CommentImageLoader>((ref) {
  return (url, {memCacheWidth}) => buildCommentImageProvider(
    url,
    memCacheWidth: memCacheWidth,
    cacheManager: AppImageCache.manager,
  );
});
