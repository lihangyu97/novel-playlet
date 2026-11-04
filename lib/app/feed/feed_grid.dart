import 'package:flutter/material.dart';

import '../widgets/novel_cover.dart';

/// 三列卡片的尺寸。
///
/// 用 `SliverGridDelegateWithFixedCrossAxisCount.mainAxisExtent` 给固定高度，
/// 而不是 `childAspectRatio`：后者在小屏 + 大字号时会按比例把两行标题挤出
/// 卡片。这里按卡片组成逐项累加，并跟随系统字号缩放。
class FeedGridMetrics {
  const FeedGridMetrics({
    required this.cellWidth,
    required this.cellHeight,
  });

  /// [coverAspect] 是封面高 / 宽，默认 [kCoverAspect]：小说流与短剧流共用
  /// 同一个比例，两个 tab 的封面才会一样大。
  factory FeedGridMetrics.of(
    BuildContext context, {
    double coverAspect = kCoverAspect,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final cellWidth =
        (width - FeedGridMetrics.horizontalPadding * 2 - FeedGridMetrics.crossAxisSpacing * 2) /
        FeedGridMetrics.columns;

    final textScaler = MediaQuery.textScalerOf(context);
    final textTheme = Theme.of(context).textTheme;
    final titleStyle = textTheme.bodyMedium;
    final metaStyle = textTheme.bodySmall;

    // 与卡片内部结构一一对应：封面 + 8 间距 + 标题两行（行高 1.25）+
    // 3 间距 + 作者/集数一行，末尾留 6 的抖动余量。
    final titleLine =
        textScaler.scale(titleStyle?.fontSize ?? 14) *
        (titleStyle?.height ?? 1.25);
    final metaLine = textScaler.scale(metaStyle?.fontSize ?? 12) * 1.4;
    final cellHeight =
        cellWidth * coverAspect + 8 + titleLine * 2 + 3 + metaLine + 6;

    return FeedGridMetrics(cellWidth: cellWidth, cellHeight: cellHeight);
  }

  static const int columns = 3;
  static const double horizontalPadding = 16;
  static const double crossAxisSpacing = 12;
  static const double mainAxisSpacing = 16;

  final double cellWidth;
  final double cellHeight;
}

/// 三列网格（sliver 形态），卡片由调用方给。
class FeedGrid<T> extends StatelessWidget {
  const FeedGrid({
    super.key,
    required this.items,
    required this.metrics,
    required this.itemBuilder,
  });

  final List<T> items;
  final FeedGridMetrics metrics;

  /// (context, item, cellWidth) -> 卡片。卡片自己带 `ValueKey(itemId)`。
  final Widget Function(BuildContext context, T item, double width) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: FeedGridMetrics.horizontalPadding,
      ),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: FeedGridMetrics.columns,
          crossAxisSpacing: FeedGridMetrics.crossAxisSpacing,
          mainAxisSpacing: FeedGridMetrics.mainAxisSpacing,
          mainAxisExtent: metrics.cellHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => itemBuilder(context, items[index], metrics.cellWidth),
          childCount: items.length,
        ),
      ),
    );
  }
}
