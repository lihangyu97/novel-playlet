import 'package:flutter/material.dart';

import '../../../app/widgets/novel_card.dart';
import '../../../app/widgets/states.dart';
import '../../../data/models/novel_item.dart';

/// 书架区：网格展示 + 空态，长按交给父级弹管理菜单。
///
/// 返回普通 Box 而不是 sliver：我的页把内容拆成三块做独立的横向延迟动画，
/// sliver 没法单独平移。书架是个人数据、量级不大，`shrinkWrap` 的 GridView
/// 一次性布局足够，换来的「能按块做动画」更重要。
class MineShelfGrid extends StatelessWidget {
  const MineShelfGrid({
    super.key,
    required this.shelf,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.spacing,
    required this.onOpen,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<NovelItem> shelf;
  final int crossAxisCount;
  final double itemWidth;
  final double itemHeight;
  final double spacing;
  final ValueChanged<NovelItem> onOpen;
  final ValueChanged<NovelItem> onLongPress;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String Function(NovelItem item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    if (shelf.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 200,
          child: EmptyView(
            message: '书架还是空的，去推荐页看看',
            icon: Icons.collections_bookmark_outlined,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 18,
          mainAxisExtent: itemHeight,
        ),
        itemCount: shelf.length,
        itemBuilder: (context, index) {
          final item = shelf[index];
          // NovelGridCard 只接了 onTap，长按手势包在外层；两者在手势竞技场
          // 里分别是 tap / long-press，不会互相吞掉。
          return GestureDetector(
            onLongPress: () => onLongPress(item),
            child: NovelGridCard(
              item: item,
              width: itemWidth,
              onTap: () => onOpen(item),
              heroTag: heroTagOf?.call(item),
            ),
          );
        },
      ),
    );
  }
}
