import 'package:flutter/material.dart';

import '../../../app/widgets/card_flight_route.dart';
import '../../../app/widgets/media_card.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../app/widgets/states.dart';
import '../../../core/storage/library_records.dart';
import 'library_type_badge.dart';
import 'shelf_grid.dart';

/// 「收藏」网格：小说与短剧混排，封面统一 3:4 裁切。
///
/// 两类内容原来的原生比例不同（小说 3:4、短剧 7:10），混排时如果各按原生
/// 比例出图，同一行会一高一低。这里统一按 [kNovelCoverAspect] 出图（短剧
/// 封面 `BoxFit.cover` 裁掉上下一点点），换取整齐的栅格；左上角彩色标签
/// 负责区分类型。
class MineLibraryGrid extends StatelessWidget {
  const MineLibraryGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.spacing,
    required this.onOpen,
    required this.onLongPress,
    required this.heroTagOf,
  });

  final List<LibraryRecord> items;
  final int crossAxisCount;
  final double itemWidth;
  final double spacing;
  final void Function(LibraryRecord item, CardRectResolver cardRect) onOpen;
  final ValueChanged<LibraryRecord> onLongPress;
  final String Function(LibraryRecord item) heroTagOf;

  @override
  Widget build(BuildContext context) {
    return ShelfGrid<LibraryRecord>(
      items: items,
      crossAxisCount: crossAxisCount,
      spacing: spacing,
      onLongPress: onLongPress,
      heroTagOf: heroTagOf,
      emptyState: const EmptyView(
        message: '收藏夹还是空的，去推荐页看看',
        icon: Icons.star_border_rounded,
      ),
      cardBuilder: (item, heroTag) => MediaCard(
        cover: item.cover,
        title: item.title,
        // 小说展示作者、短剧展示集数；两者都空时不留空行。
        meta: item.type.isPlaylet
            ? (item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : '')
            : item.author,
        coverOverlay: LibraryTypeBadge(type: item.type),
        width: itemWidth,
        onTap: (cardRect) => onOpen(item, cardRect),
        heroTag: heroTag,
        // 混排统一 3:4：短剧封面会被轻微裁切，换来同一行高度一致。
        coverAspect: kNovelCoverAspect,
        surface: true,
        naturalTitleHeight: true,
      ),
    );
  }
}
