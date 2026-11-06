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
/// 详情页固定沿用列表带过来的封面（见 `DetailCoverHeader`），不会在接口回来
/// 后换成另一张 URL，所以这里只处理"一张图从占位到就绪"的淡入，不需要垫图
/// 或换图逻辑。
class NovelCover extends StatelessWidget {
  const NovelCover({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.radius = 10,
    this.fadeInDuration = const Duration(milliseconds: 120),
  });

  final String url;
  final double width;
  final double height;
  final double radius;

  /// 主图就绪后的淡入时长；详情页大封面传 [Duration.zero] 直接替换。
  final Duration fadeInDuration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: url,
                cacheManager: AppImageCache.manager,
                fit: BoxFit.cover,
                width: width,
                height: height,
                // 推荐流 108pt / 搜索结果 64pt / 书架与最近阅读 44pt 共用本
                // 组件，上游封面却可能是 500–1440px 的原图（单张 1–3MB）。
                // 按目标显示尺寸的物理像素解码，否则 44pt 的格位也会解出一张
                // 1080px 的 RGBA（4–6MB），默认 100MB 的 ImageCache 只装得下
                // 约 20 张，来回滑动时就会反复解码 / 驱逐。
                memCacheWidth: (width * dpr).round(),
                // 磁盘缓存也别存原图：这些格位都用不到 720 宽以上的细节。
                maxWidthDiskCache: 720,
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
                // 详情页传 zero：图片就绪立即出现，不再做淡入替换动画。
                fadeInDuration: fadeInDuration,
              ),
      ),
    );
  }
}
