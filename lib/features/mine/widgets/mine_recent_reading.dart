import 'package:flutter/material.dart';

import '../../../core/storage/reading_store.dart';
import 'mine_recent_tile.dart';

/// 最近阅读区：封面 + 书名 + 读到第几章 + 相对时间，点击直接续读。
///
/// 与书架不同，这里的每一条都是可续读的进度记录，所以点击目标是阅读页
/// 而不是详情页（省掉"进详情再找章"的一步）。
///
/// 返回普通 Box 而不是 sliver：我的页把内容拆成「头部 / 最近阅读 / 书架」三块，
/// 每块要独立做横向延迟动画，sliver 没法单独平移。
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            MineRecentTile(
              cover: items[i].cover,
              title: items[i].bookTitle.isEmpty ? '未命名作品' : items[i].bookTitle,
              subtitle: items[i].chapterId.isEmpty
                  ? '尚未开始阅读'
                  : '读到第 ${items[i].chapterIndex + 1} 章',
              updatedAt: items[i].updatedAt,
              onTap: () => onOpen(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}
