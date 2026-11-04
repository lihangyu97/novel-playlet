import 'package:flutter/material.dart';

import '../../../app/widgets/novel_card.dart';
import '../../../data/models/novel_item.dart';

/// 三列网格的尺寸。
///
/// 用 [SliverGridDelegateWithFixedCrossAxisCount.mainAxisExtent] 给固定高度，
/// 而不是 `childAspectRatio`：后者在小屏 + 大字号时会按比例把两行标题挤出
/// 卡片。这里按卡片组成逐项累加，并跟随系统字号缩放。
class RecommendGridMetrics {
  const RecommendGridMetrics({
    required this.cellWidth,
    required this.cellHeight,
  });

  factory RecommendGridMetrics.of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cellWidth =
        (width - horizontalPadding * 2 - crossAxisSpacing * 2) / columns;

    final textScaler = MediaQuery.textScalerOf(context);
    final textTheme = Theme.of(context).textTheme;
    final titleStyle = textTheme.bodyMedium;
    final metaStyle = textTheme.bodySmall;

    // 与 NovelGridCard 内部结构一一对应：封面（宽 × 1.38）+ 8 间距 +
    // 标题两行（行高 1.25）+ 3 间距 + 作者一行，末尾留 6 的抖动余量。
    final titleLine =
        textScaler.scale(titleStyle?.fontSize ?? 14) *
        (titleStyle?.height ?? 1.25);
    final metaLine = textScaler.scale(metaStyle?.fontSize ?? 12) * 1.4;
    final cellHeight = cellWidth * 1.38 + 8 + titleLine * 2 + 3 + metaLine + 6;

    return RecommendGridMetrics(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
    );
  }

  static const int columns = 3;
  static const double horizontalPadding = 16;
  static const double crossAxisSpacing = 12;
  static const double mainAxisSpacing = 16;

  final double cellWidth;
  final double cellHeight;
}

/// 推荐流的三列网格（sliver 形态，交给页面的 CustomScrollView 承载）。
class RecommendGridSliver extends StatelessWidget {
  const RecommendGridSliver({
    super.key,
    required this.items,
    required this.metrics,
    required this.onTap,
  });

  final List<NovelItem> items;
  final RecommendGridMetrics metrics;
  final ValueChanged<NovelItem> onTap;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: RecommendGridMetrics.horizontalPadding,
      ),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: RecommendGridMetrics.columns,
          crossAxisSpacing: RecommendGridMetrics.crossAxisSpacing,
          mainAxisSpacing: RecommendGridMetrics.mainAxisSpacing,
          mainAxisExtent: metrics.cellHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            return NovelGridCard(
              // 用书 id 而不是下标：翻页追加时已有卡片不会因为重建而丢状态。
              key: ValueKey(item.id),
              item: item,
              width: metrics.cellWidth,
              onTap: () => onTap(item),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }
}
