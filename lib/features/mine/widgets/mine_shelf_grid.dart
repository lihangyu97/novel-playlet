import 'package:flutter/material.dart';

import '../../../app/widgets/novel_card.dart';
import '../../../app/widgets/states.dart';
import '../../../data/models/novel_item.dart';

/// 书架区：网格展示 + 空态，长按交给父级弹管理菜单。
///
/// 单独抽成 sliver 组件，是为了让书架网格跟着整页的 [CustomScrollView]
/// 一起滚动并享受懒加载，而不是嵌在 ListView 里再套一层 GridView。
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
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 200,
            child: EmptyView(
              message: '书架还是空的，去推荐页看看',
              icon: Icons.collections_bookmark_outlined,
            ),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 18,
          mainAxisExtent: itemHeight,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
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
        }, childCount: shelf.length),
      ),
    );
  }
}
