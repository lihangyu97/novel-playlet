import 'package:flutter/material.dart';

import '../../../core/storage/reading_store.dart';
import 'mine_recent_tile.dart';

/// 短剧最近观看：版式与小说「最近阅读」完全一致（封面在左、箭头在右），
/// 只是副标题换成「看到第 N 集」，点击直接进播放页续播。
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            MineRecentTile(
              cover: items[i].cover,
              title: items[i].title.isEmpty ? '未命名短剧' : items[i].title,
              subtitle: '看到第 ${items[i].episodeIndex + 1} 集',
              updatedAt: items[i].updatedAt,
              onTap: () => onOpen(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}
