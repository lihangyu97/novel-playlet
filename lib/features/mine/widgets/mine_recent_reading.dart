import 'package:flutter/material.dart';

import '../../../app/widgets/novel_cover.dart';
import '../../../core/storage/reading_store.dart';
import 'mine_recent_tile.dart';
import 'recent_list.dart';

/// 最近阅读区：封面 + 书名 + 读到第几章 + 相对时间，点击直接续读。
///
/// 与书架不同，这里的每一条都是可续读的进度记录，所以点击目标是阅读页
/// 而不是详情页（省掉"进详情再找章"的一步）。
///
/// 列表骨架见 [RecentList]；这里只负责阅读进度的取文案规则。
class MineRecentReading extends StatelessWidget {
  const MineRecentReading({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<ReadingProgress> items;
  final ValueChanged<ReadingProgress> onOpen;

  @override
  Widget build(BuildContext context) {
    return RecentList<ReadingProgress>(
      items: items,
      tileOf: (item) => MineRecentTile(
        cover: item.cover,
        coverAspect: kNovelCoverAspect,
        title: item.bookTitle.isEmpty ? '未命名作品' : item.bookTitle,
        subtitle: item.chapterId.isEmpty
            ? '尚未开始阅读'
            : '读到第 ${item.chapterIndex + 1} 章',
        updatedAt: item.updatedAt,
        onTap: () => onOpen(item),
      ),
    );
  }
}
