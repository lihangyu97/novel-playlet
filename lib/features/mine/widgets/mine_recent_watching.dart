import 'package:flutter/material.dart';

import '../../../app/widgets/novel_cover.dart';
import '../../../core/storage/reading_store.dart';
import 'mine_recent_tile.dart';
import 'recent_list.dart';

/// 短剧最近观看：版式与小说「最近阅读」完全一致（封面在左、箭头在右），
/// 只是副标题换成「看到第 N 集」，点击直接进播放页续播。
///
/// 列表骨架见 [RecentList]；这里只负责观看进度的取文案规则。
class MineRecentWatching extends StatelessWidget {
  const MineRecentWatching({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<VideoWatchProgress> items;
  final ValueChanged<VideoWatchProgress> onOpen;

  @override
  Widget build(BuildContext context) {
    return RecentList<VideoWatchProgress>(
      items: items,
      tileOf: (item) => MineRecentTile(
        cover: item.cover,
        coverAspect: kVideoCoverAspect,
        title: item.title.isEmpty ? '未命名短剧' : item.title,
        subtitle: '看到第 ${item.episodeIndex + 1} 集',
        updatedAt: item.updatedAt,
        onTap: () => onOpen(item),
      ),
    );
  }
}
