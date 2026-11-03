import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';

/// 统一的书籍封面：固定圆角、占位底色、失败兜底。
///
/// 上游封面 URL 可能是 http、可能为空、可能 403，所以不能直接用
/// `Image.network`：失败时给灰色占位而不是红色报错块。
///
/// [fallbackUrl] 是"上一张已经在缓存里的图"（例如列表卡片用的 `thumb_url`）：
/// 详情接口会换成更高清的 `detail_page_thumb_url`，URL 不同就必然重新下载。
/// 有 fallback 时先垫着旧图，新图就绪后**直接替换**（配合
/// `fadeInDuration: Duration.zero`），避免"灰块 → 淡入"的刷新感。
class NovelCover extends StatelessWidget {
  const NovelCover({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.radius = 10,
    this.fallbackUrl = '',
    this.fadeInDuration = const Duration(milliseconds: 120),
  });

  final String url;
  final double width;
  final double height;
  final double radius;

  /// 主图加载期间的垫图（通常是列表里已经加载过的那张）。
  final String fallbackUrl;

  /// 主图就绪后的淡入时长；详情页大封面传 [Duration.zero] 直接替换。
  final Duration fadeInDuration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book_outlined,
        size: width * 0.4,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );

    Widget image(String imageUrl, {required bool isFallback}) =>
        CachedNetworkImage(
          imageUrl: imageUrl,
          cacheManager: AppImageCache.manager,
          fit: BoxFit.cover,
          width: width,
          height: height,
          // 主图加载时不要盖住垫图：透明占位 + 零淡入，就绪即替换。
          placeholder: (_, _) =>
              isFallback ? placeholder : const SizedBox.shrink(),
          errorWidget: (_, _, _) => isFallback
              ? placeholder
              : const SizedBox.shrink(),
          fadeInDuration: isFallback ? Duration.zero : fadeInDuration,
        );

    final hasFallback = fallbackUrl.isNotEmpty && fallbackUrl != url;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? placeholder
            : hasFallback
            ? Stack(
                fit: StackFit.expand,
                children: [
                  image(fallbackUrl, isFallback: true),
                  image(url, isFallback: false),
                ],
              )
            : image(url, isFallback: true),
      ),
    );
  }
}
