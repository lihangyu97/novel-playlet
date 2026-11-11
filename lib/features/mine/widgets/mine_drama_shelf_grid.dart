import 'package:flutter/material.dart';

import '../../../app/widgets/states.dart';
import '../../../data/models/video_series.dart';
import '../../video/widgets/video_card.dart';
import 'shelf_grid.dart';

/// 短剧 tab 的收藏区：网格展示 + 空态，长按交给父级弹管理菜单。
///
/// 与小说侧的 [MineShelfGrid] 同一套网格尺寸/间距/空态（骨架见 [ShelfGrid]），
/// 只是卡片换成 [VideoCard]（元信息是集数）。
class MineDramaShelfGrid extends StatelessWidget {
  const MineDramaShelfGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.spacing,
    required this.coverAspect,
    required this.onOpen,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<VideoSeries> items;
  final int crossAxisCount;
  final double itemWidth;
  final double spacing;

  /// 封面原生比例（高 / 宽）：短剧 7:10。
  final double coverAspect;
  final ValueChanged<VideoSeries> onOpen;
  final ValueChanged<VideoSeries> onLongPress;
  final String Function(VideoSeries item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    return ShelfGrid<VideoSeries>(
      items: items,
      crossAxisCount: crossAxisCount,
      spacing: spacing,
      onLongPress: onLongPress,
      heroTagOf: heroTagOf,
      emptyState: const EmptyView(
        message: '还没有收藏的短剧，去推荐页看看',
        icon: Icons.video_collection_outlined,
      ),
      cardBuilder: (item, heroTag) => VideoCard(
        item: item,
        width: itemWidth,
        onTap: () => onOpen(item),
        heroTag: heroTag,
        // 与首页同款白底不定高卡片；收藏只展示剧名 + 集数。
        surface: true,
        naturalTitleHeight: true,
        coverAspect: coverAspect,
      ),
    );
  }
}
