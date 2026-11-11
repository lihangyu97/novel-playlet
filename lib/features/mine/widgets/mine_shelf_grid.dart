import 'package:flutter/material.dart';

import '../../../app/widgets/novel_card.dart';
import '../../../app/widgets/states.dart';
import '../../../data/models/novel_item.dart';
import 'shelf_grid.dart';

/// 小说 tab 的书架区：网格展示 + 空态，长按交给父级弹管理菜单。
///
/// 网格骨架见 [ShelfGrid]；这里只负责把 [NovelItem] 映射成 [NovelGridCard]、
/// 给出小说侧的空白文案。
class MineShelfGrid extends StatelessWidget {
  const MineShelfGrid({
    super.key,
    required this.shelf,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.spacing,
    required this.coverAspect,
    required this.onOpen,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<NovelItem> shelf;
  final int crossAxisCount;
  final double itemWidth;
  final double spacing;

  /// 封面原生比例（高 / 宽）：小说 3:4。
  final double coverAspect;
  final ValueChanged<NovelItem> onOpen;
  final ValueChanged<NovelItem> onLongPress;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String Function(NovelItem item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    return ShelfGrid<NovelItem>(
      items: shelf,
      crossAxisCount: crossAxisCount,
      spacing: spacing,
      onLongPress: onLongPress,
      heroTagOf: heroTagOf,
      emptyState: const EmptyView(
        message: '书架还是空的，去推荐页看看',
        icon: Icons.collections_bookmark_outlined,
      ),
      cardBuilder: (item, heroTag) => NovelGridCard(
        item: item,
        width: itemWidth,
        onTap: () => onOpen(item),
        heroTag: heroTag,
        // 与首页同款白底不定高卡片；书架只展示书名 + 作者，作者缺失时
        // 不拿分类顶替（[NovelGridCard.fallbackToCategory]）。
        surface: true,
        naturalTitleHeight: true,
        fallbackToCategory: false,
        coverAspect: coverAspect,
      ),
    );
  }
}
