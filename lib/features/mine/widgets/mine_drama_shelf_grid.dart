import 'package:flutter/material.dart';

import '../../../app/widgets/states.dart';
import '../../../data/models/video_series.dart';
import '../../video/widgets/video_card.dart';

/// 短剧收藏区：网格展示 + 空态，长按交给父级弹管理菜单。
///
/// 与小说侧的 [MineShelfGrid] 同一套网格尺寸/间距/空态，只是卡片换成
/// [VideoCard]（元信息是集数）。
class MineDramaShelfGrid extends StatelessWidget {
  const MineDramaShelfGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.spacing,
    required this.onOpen,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<VideoSeries> items;
  final int crossAxisCount;
  final double itemWidth;
  final double itemHeight;
  final double spacing;
  final ValueChanged<VideoSeries> onOpen;
  final ValueChanged<VideoSeries> onLongPress;
  final String Function(VideoSeries item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          height: 200,
          child: EmptyView(
            message: '还没有收藏的短剧，去推荐页看看',
            icon: Icons.video_collection_outlined,
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
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return GestureDetector(
            onLongPress: () => onLongPress(item),
            child: VideoCard(
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
