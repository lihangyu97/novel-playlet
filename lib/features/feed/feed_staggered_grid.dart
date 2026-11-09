import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// 瀑布流网格（sliver 形态）：卡片不定高，按列自上而下排。
///
/// 用 `flutter_staggered_grid_view` 的 [SliverMasonryGrid]：它按子节点的
/// 实际高度排版（真的测量、不靠估高），本身是 sliver，两/三列都懒加载，
/// 翻页追加和下拉刷新都能直接复用 [FeedView] 的滚动骨架。
///
/// 不自己手写 RenderSliver：瀑布流的测量、回收与滚动缓存细节很多，社区
/// 实现的稳定性更重要（依赖白名单见 CONTRACTS.md）。
class FeedStaggeredGrid<T> extends StatelessWidget {
  const FeedStaggeredGrid({
    super.key,
    required this.items,
    required this.columns,
    required this.itemBuilder,
  });

  final List<T> items;

  /// 列数（双列 / 三列），由设置里的首页推荐布局决定。
  final int columns;

  /// (context, item, cellWidth) -> 卡片。卡片自己带 `ValueKey(itemId)`。
  ///
  /// cellWidth 与 masonry 实际给的紧约束完全一致（同一个 SliverConstraints
  /// 算出来的），卡片可以直接按它算封面高度。
  final Widget Function(BuildContext context, T item, double width) itemBuilder;

  /// 左右留白（与详情/搜索一致）。
  static const double horizontalPadding = 16;

  /// 列间距。
  static const double crossAxisSpacing = 12;

  /// 行间距：瀑布流里上下两张卡之间的距离。
  ///
  /// 比旧三列网格的 16 小一档：白底卡片本身有底色边界，行间距再大整页会显得
  /// 松散；12 在双列卡片之间仍能看清两列。
  static const double mainAxisSpacing = 12;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
      // 用 sliver 自己拿到的 crossAxisExtent 算列宽，而不是 MediaQuery 屏宽：
      // 外层一旦加留白/安全区或被放进窄容器（iPad 分屏），两者就不相等，
      // 卡片会比列窄、封面比例也跟着失真。SliverLayoutBuilder 的约束与
      // masonry 内部口径一致，逐帧同步。
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final cellWidth =
              (constraints.crossAxisExtent - crossAxisSpacing * (columns - 1)) /
              columns;
          return SliverMasonryGrid.count(
            crossAxisCount: columns,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: crossAxisSpacing,
            childCount: items.length,
            itemBuilder: (context, index) =>
                itemBuilder(context, items[index], cellWidth),
          );
        },
      ),
    );
  }
}
