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
///
/// 性能（CODE_REVIEW P1-6）：[SliverLayoutBuilder] 的 builder 在**每次布局**
/// 都会执行（滚动时 `SliverConstraints.scrollOffset` 每帧都变）。如果每次都在
/// builder 里 new 一个 [SliverMasonryGrid]，新的
/// `SliverChildBuilderDelegate.shouldRebuild` 恒为 true，会让
/// `SliverMultiBoxAdaptorElement.performRebuild` 重建所有已构建卡片——等于把
/// masonry 的懒加载收益抵消掉。这里把"算列宽"和"建 sliver"解耦：列数 / 列宽
/// / 列表身份都没变时直接复用同一个 sliver 实例，Flutter 的 `updateChild`
/// 对 identical widget 会短路，卡片不重建。
///
/// 复用只发生在"数据与布局都没变"的情况下；缓存的 sliver 在真正懒构建某张
/// 卡片时才读取 `widget.itemBuilder/items`，所以页面重建传入新的 builder 闭包
/// （例如 footer 的 loadingMore 变化）不会用到旧闭包。
class FeedStaggeredGrid<T> extends StatefulWidget {
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

  /// 左右留白：与顶部搜索框区域的边距一致（都是 8），列表和搜索框左右对齐。
  static const double horizontalPadding = 8;

  /// 列间距。
  static const double crossAxisSpacing = 8;

  /// 行间距：瀑布流里上下两张卡之间的距离。
  ///
  /// 比旧三列网格的 16 小两档：白底卡片本身有底色边界，行间距再大整页会显得
  /// 松散；8 在双列卡片之间仍能看清两列（原 12 再收 2/3）。
  static const double mainAxisSpacing = 8;

  @override
  State<FeedStaggeredGrid<T>> createState() => _FeedStaggeredGridState<T>();
}

class _FeedStaggeredGridState<T> extends State<FeedStaggeredGrid<T>> {
  /// 上次构建的 masonry sliver，以及它对应的输入指纹。
  ///
  /// 只缓存 sliver 本身（列宽在内层闭包里捕获），不缓存外层
  /// [SliverLayoutBuilder]：builder 仍要每帧执行一次读 constraints，但命中缓存
  /// 后就只是一次字段比较，不再触发子节点重建。
  Widget? _cachedSliver;
  double? _cachedCellWidth;
  int? _cachedColumns;
  List<T>? _cachedItems;
  int? _cachedItemCount;

  bool _canReuseSliver(double cellWidth) {
    final cached = _cachedSliver;
    return cached != null &&
        _cachedCellWidth == cellWidth &&
        _cachedColumns == widget.columns &&
        identical(_cachedItems, widget.items) &&
        _cachedItemCount == widget.items.length;
  }

  Widget _buildSliver(double cellWidth) {
    // itemBuilder 闭包每次被 masonry 真正调用时才读取当前 widget 的 items /
    // itemBuilder：复用的只是 sliver 结构与布局，不是某一帧的卡片定义。
    final sliver = SliverMasonryGrid.count(
      crossAxisCount: widget.columns,
      mainAxisSpacing: FeedStaggeredGrid.mainAxisSpacing,
      crossAxisSpacing: FeedStaggeredGrid.crossAxisSpacing,
      childCount: widget.items.length,
      itemBuilder: (context, index) =>
          widget.itemBuilder(context, widget.items[index], cellWidth),
    );
    _cachedSliver = sliver;
    _cachedCellWidth = cellWidth;
    _cachedColumns = widget.columns;
    _cachedItems = widget.items;
    _cachedItemCount = widget.items.length;
    return sliver;
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(
        horizontal: FeedStaggeredGrid.horizontalPadding,
      ),
      // 用 sliver 自己拿到的 crossAxisExtent 算列宽，而不是 MediaQuery 屏宽：
      // 外层一旦加留白/安全区或被放进窄容器（iPad 分屏），两者就不相等，
      // 卡片会比列窄、封面比例也跟着失真。SliverLayoutBuilder 的约束与
      // masonry 内部口径一致，逐帧同步。
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final cellWidth =
              (constraints.crossAxisExtent -
                  FeedStaggeredGrid.crossAxisSpacing * (widget.columns - 1)) /
              widget.columns;
          if (_canReuseSliver(cellWidth)) return _cachedSliver!;
          return _buildSliver(cellWidth);
        },
      ),
    );
  }
}
