import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';

/// 封面统一比例（高 / 宽）= 11:8 = 1.375。
///
/// 上游两条流给的原生比例并不一样：小说封面 240×320、详情大图 600×800
/// （3:4 ≈ 1.333），短剧封面 400×571（≈ 1.4275）。各用各的比例时，同为
/// 三列的推荐流里短剧封面会比小说矮约 5pt，切 tab 一眼能看出高度不齐。
///
/// 这里取两者中间的 11:8：双方各裁掉不到 4% 的边缘（`BoxFit.cover` 居中裁），
/// 换来小说/短剧封面**同宽同高**。详情页封面 96×132、搜索条目 66×90 本来
/// 就贴着这个比例，所以列表 → 详情的封面过渡也不会跳。
const double kCoverAspect = 11 / 8;

/// 统一的书籍封面：固定圆角、占位底色、失败兜底。
///
/// 上游封面 URL 可能是 http、可能为空、可能 403，所以不能直接用
/// `Image.network`：失败时给灰色占位而不是红色报错块。
///
/// [fallbackUrl] 是"上一张已经在缓存里的图"：正常情况下列表与详情取的是同一张
/// 缩略图（见 `coverKeys`），两者相等时不会出现两个图层；只有详情退到更大的
/// 兜底图、URL 确实不同时，才先用旧图垫着，新图就绪后**直接替换**（配合
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

    // `asFallbackLayer` 指"垫在另一张图下面"的旧图：那层不能淡入，否则
    // 换图时会闪一下。列表封面没有垫图层，走正常短淡入，图片就绪时不是
    // 灰块硬切，观感更稳。
    Widget image(String imageUrl, {required bool asFallbackLayer}) =>
        CachedNetworkImage(
          imageUrl: imageUrl,
          cacheManager: AppImageCache.manager,
          fit: BoxFit.cover,
          width: width,
          height: height,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
          fadeInDuration: asFallbackLayer ? Duration.zero : fadeInDuration,
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
                  image(fallbackUrl, asFallbackLayer: true),
                  image(url, asFallbackLayer: false),
                ],
              )
            : image(url, asFallbackLayer: false),
      ),
    );
  }
}
