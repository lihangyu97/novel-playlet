import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';

/// 封面统一比例（高 / 宽）= 11:8 = 1.375，是**固定网格的默认值**。
///
/// 上游各内容域的原生比例并不一样：小说封面 240×320（宽:高 = 3:4，即高/宽 =
/// 4/3 ≈ 1.333），短剧/漫剧封面 400×571（高/宽 ≈ 1.4275）。各用各的比例时，
/// 固定网格里短剧封面会比小说矮约 5pt，切 tab 一眼能看出高度不齐。
///
/// 所以固定网格（书架、搜索结果、最近阅读、详情）统一取两者中间的 11:8：
/// 双方各裁掉不到 4% 的边缘（`BoxFit.cover` 居中裁），换来小说/短剧封面
/// **同宽同高**。推荐流瀑布流不用它，见 [kNovelCoverAspect] / [kVideoCoverAspect]。
const double kCoverAspect = 11 / 8;

/// 封面圆角（固定网格用）。推荐流卡片化时传 0，由卡片自己裁圆角。
const double kCoverRadius = 10;

/// 上游封面各内容域的原生比例（高 / 宽），只给推荐流瀑布流用。
///
/// 与 [kCoverAspect] 的关系：小说 320/240 = 4/3 ≈ 1.333（宽:高 = 3:4），
/// 短剧/漫剧 571/400 ≈ 1.4275；11:8 = 1.375 正好是两者中间。
/// 推荐流改成不定高卡片后不再需要"同宽同高"：按原生比例出图可以不裁封面，
/// 小说封面自然比短剧/漫剧略矮，瀑布流的高低差也就有了。
///
/// 接口不返回封面尺寸；列表实际取的是 `thumb_url` 缩略图，这里按上游原始
/// 封面的实测尺寸（240×320 / 400×571）认为缩略图同比例，没有逐图校验。
/// 上游换尺寸时改这两个常量即可；不要按单张图去解码量尺寸——那会让瀑布流
/// 在图片就绪后二次重排。
const double kNovelCoverAspect = 320 / 240;
const double kVideoCoverAspect = 571 / 400;

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
    this.radius = kCoverRadius,
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
