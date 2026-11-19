import 'package:flutter/material.dart';

import '../../app/widgets/media_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/skeleton.dart';
import '../../app/widgets/surface_card.dart';
import '../feed/feed_staggered_grid.dart';
import 'recommend_category.dart';

/// 推荐流的首屏骨架：和真卡同列宽、同封面比例、同文字行高的色块占位。
///
/// 首屏请求还没回来时铺满一屏，数据到达后整块被 `FeedView` 顶掉。骨架卡的
/// 高度按「标题 1 / 2 行 + 是否有附加元信息」轮换，和真瀑布流的高低错落一致，
/// 换真卡时不会整屏跳版。
///
/// 不滚动（加载态还没有可翻的内容），也不做 shimmer 动画：和搜索页的
/// `CompactSkeletonRow` 一样用静态色块，浅色/深色主题各自一档灰
/// （见 [skeletonBlockColor]）。
class RecommendFeedSkeleton extends StatelessWidget {
  const RecommendFeedSkeleton({
    super.key,
    required this.category,
    required this.columns,
  });

  final RecommendCategory category;

  /// 当前布局的列数（`RecommendLayout.columns`）：骨架必须和真卡同一套
  /// 网格口径，否则双列/三列切换时首屏会先按旧列数闪一下。
  final int columns;

  /// 骨架张数：约 4 行，够盖住首屏再露一点下沿；masonry 只构建视口内可见的
  /// 那几张，多余的不会产生布局开销。
  int get _cardCount => columns * 4;

  /// 封面原生比例：小说 3:4，短剧/漫剧 7:10（与真卡同一口径）。
  double get _coverAspect => category == RecommendCategory.novel
      ? kNovelCoverAspect
      : kVideoCoverAspect;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '正在加载${category.label}',
      child: CustomScrollView(
        key: ValueKey('recommend-skeleton-${category.name}'),
        // 骨架本身不可滚：下拉刷新/触底翻页都还没有落在内容上。
        physics: const NeverScrollableScrollPhysics(),
        slivers: [
          FeedStaggeredGrid<int>(
            items: List<int>.generate(_cardCount, (index) => index),
            columns: columns,
            itemBuilder: (context, index, width) => _SkeletonCard(
              width: width,
              coverAspect: _coverAspect,
              index: index,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一张骨架卡：白底卡 + 封面块 + 标题/元信息色块。
///
/// 行高口径直接复用 [MediaCard]：标题 bodyMedium + [MediaCard.titleLineHeightFactor]，
/// 元信息 bodySmall 自身行高；封面满宽出血、文字区左右 10 的内边距都与真卡
/// 一致，所以骨架和真卡同宽同高。
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({
    required this.width,
    required this.coverAspect,
    required this.index,
  });

  final double width;
  final double coverAspect;

  /// 第几张骨架卡：只用来按确定性规则轮换高度，不参与交互。
  final int index;

  /// 文字区内边距，与 [MediaCard] `surface` 形态保持一致。
  static const _textPadding = EdgeInsets.fromLTRB(10, 8, 10, 10);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final titleStyle = theme.textTheme.bodyMedium;
    final titleLineHeight =
        textScaler.scale(titleStyle?.fontSize ?? 14) *
        MediaCard.titleLineHeightFactor;
    final metaStyle = theme.textTheme.bodySmall;
    final metaLineHeight =
        textScaler.scale(metaStyle?.fontSize ?? 12) *
        (metaStyle?.height ?? 1.0);
    // 色块宽度按「文字区可用宽」算，左右内边距之外不能溢出卡片。
    final contentWidth = width > _textPadding.horizontal
        ? width - _textPadding.horizontal
        : 0.0;

    // 高度轮换：约 1/3 的卡只有一行标题，约 1/4 的卡多一行附加元信息
    // （真卡的推荐理由/热度），其余是两行标题 + 一行元信息。
    final titleLines = index % 3 == 2 ? 1 : 2;
    final hasExtraMeta = index % 4 == 1;

    Widget line(double lineHeight, double widthRatio, double heightRatio) {
      return SizedBox(
        height: lineHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: SkeletonBar(
            width: contentWidth * widthRatio,
            height: lineHeight * heightRatio,
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      child: AppSurfaceCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: width, height: width * coverAspect),
            Padding(
              padding: _textPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var lineIndex = 0; lineIndex < titleLines; lineIndex++)
                    line(titleLineHeight, lineIndex == 0 ? 0.72 : 0.44, 0.58),
                  const SizedBox(height: 3),
                  line(metaLineHeight, 0.34, 0.6),
                  if (hasExtraMeta) ...[
                    const SizedBox(height: 2),
                    line(metaLineHeight, 0.5, 0.6),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
