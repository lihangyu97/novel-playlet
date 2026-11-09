import 'package:flutter/material.dart';

/// 我的页的网格块：网格 + 空态，长按交给父级弹管理菜单。
///
/// 返回普通 Box 而不是 sliver：我的页把内容拆成三块做独立的横向延迟动画，
/// sliver 没法单独平移。书架是个人数据、量级不大，`shrinkWrap` 的 GridView
/// 一次性布局足够，换来的「能按块做动画」更重要。
///
/// 小说 / 短剧共用这层骨架：列数、卡片宽高、间距、空态高度都按同一套规则，
/// 两侧只注入卡片类型与空态文案。
class ShelfGrid<T> extends StatelessWidget {
  const ShelfGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.spacing,
    required this.cardBuilder,
    required this.emptyState,
    required this.onOpen,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<T> items;
  final int crossAxisCount;
  final double itemWidth;
  final double itemHeight;
  final double spacing;

  /// 卡片构建：拿到条目与 [heroTagOf] 算出的 Hero tag。
  final Widget Function(T item, String? heroTag) cardBuilder;
  final ValueChanged<T> onOpen;
  final ValueChanged<T> onLongPress;

  /// 空态内容（图标 + 文案）；外层留白与高度由本组件统一。
  final Widget emptyState;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String Function(T item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(height: 200, child: emptyState),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 8,
          mainAxisExtent: itemHeight,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          // 卡片只接了 onTap，长按手势包在外层；两者在手势竞技场里分别是
          // tap / long-press，不会互相吞掉。
          return GestureDetector(
            onLongPress: () => onLongPress(item),
            child: cardBuilder(item, heroTagOf?.call(item)),
          );
        },
      ),
    );
  }
}
