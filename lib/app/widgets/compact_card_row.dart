import 'package:flutter/material.dart';

import 'media_card.dart';
import 'surface_card.dart';

/// 紧凑卡行：一行横向可滑的小号卡片（搜索结果行、首页榜单预览行共用）。
///
/// 口径与搜索结果页一致：一屏露出 3.5 张卡（第 4 张只露半边，暗示可以往右
/// 滑），卡片宽度按屏宽算、卡片内部字号整体缩一档（首页同款卡片的「小号
/// 版」）。卡片本身仍复用 `NovelGridCard` / `VideoCard`（`surface: true`
/// 白底卡），这里只负责宽度、字号与行内间距——两处各写一套的话，同一张卡在
/// 搜索页和首页榜单预览里会尺寸不一。
class CompactCardRow extends StatelessWidget {
  const CompactCardRow({super.key, required this.children});

  /// 卡片行左右留白与卡片间距：与首页推荐流一致（8）。
  static const double rowPadding = 8;
  static const double cardGap = 8;

  /// 一屏露出的卡片数：3 张完整卡 + 半张。
  static const double visibleCards = 3.5;

  /// 卡片字号相对首页缩小的比例。
  ///
  /// 卡宽只有首页双列的一半多一点，字号不缩会让标题/元信息显得又大又挤；
  /// 缩一档后标题仍放得下两行，才像「同款卡片的小号版」。
  static const double cardFontScale = 0.88;

  /// 屏幕宽度 → 卡宽：3 张完整卡之间 3 个间距，两侧各 [rowPadding]。
  static double cardWidthFor(double maxWidth) =>
      (maxWidth - rowPadding * 2 - cardGap * 3) / visibleCards;

  /// 整行统一的紧凑字型：卡片宽度变了但字号还是首页尺寸会「字挤满卡」。
  static ThemeData compactTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      textTheme: theme.textTheme.apply(fontSizeFactor: cardFontScale),
    );
  }

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: rowPadding),
      child: Theme(
        data: compactTheme(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(right: cardGap),
                child: child,
              ),
          ],
        ),
      ),
    );
  }
}

/// 紧凑卡行的加载骨架：与真卡同宽同高的色块占位。
///
/// 搜索页两行并行请求，哪一行先回来哪一行先换成真卡；首页榜单预览也在
/// 接口还没回来时铺同样的骨架，避免「先没有、切回来才出现」的错觉。
class CompactSkeletonRow extends StatelessWidget {
  const CompactSkeletonRow({
    super.key,
    required this.width,
    required this.coverAspect,
    this.count = 4,
  });

  final double width;
  final double coverAspect;

  /// 铺几张骨架；搜索页用 4 张（第 4 张压在屏幕边上），榜单预览只预览 3 条。
  final int count;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: CompactCardRow.rowPadding,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.only(right: CompactCardRow.cardGap),
              child: _CompactSkeletonCard(
                width: width,
                coverAspect: coverAspect,
              ),
            ),
        ],
      ),
    );
  }
}

/// 骨架卡：白底卡 + 封面/标题/元信息三处色块。
///
/// 高度口径和真卡（[MediaCard]）一致：封面按内容域原生比例，文字区用同一个
/// 「字号缩一档」后的行高算两行标题 + 一行元信息，换真卡时行高不跳。
class _CompactSkeletonCard extends StatelessWidget {
  const _CompactSkeletonCard({required this.width, required this.coverAspect});

  final double width;
  final double coverAspect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final compactTextTheme = theme.textTheme.apply(
      fontSizeFactor: CompactCardRow.cardFontScale,
    );
    final titleLineHeight =
        textScaler.scale(compactTextTheme.bodyMedium?.fontSize ?? 14) *
        MediaCard.titleLineHeightFactor;
    final metaLineHeight =
        textScaler.scale(compactTextTheme.bodySmall?.fontSize ?? 12) *
        (compactTextTheme.bodySmall?.height ?? 1.0);
    // 浅色卡上用很浅的灰；深色卡上用略亮一档，和卡片底色区分开。
    final blockColor = scheme.onSurface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.14 : 0.07,
    );

    Widget bar(double barWidth, double barHeight) => Container(
      width: barWidth,
      height: barHeight,
      decoration: BoxDecoration(
        color: blockColor,
        borderRadius: BorderRadius.circular(barHeight / 2),
      ),
    );

    return SizedBox(
      width: width,
      child: AppSurfaceCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              height: width * coverAspect,
              color: blockColor,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题固定两行（与真卡 naturalTitleHeight=false 时一致）。
                  SizedBox(
                    height: titleLineHeight * 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(width * 0.5, titleLineHeight * 0.58),
                        const SizedBox(height: 6),
                        bar(width * 0.35, titleLineHeight * 0.58),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  bar(width * 0.28, metaLineHeight * 0.6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
