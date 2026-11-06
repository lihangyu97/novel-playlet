import 'package:flutter/material.dart';

import 'mine_recent_tile.dart';

/// 「最近阅读 / 最近观看」共用的列表骨架：逐条渲染 [MineRecentTile]。
///
/// 版式（封面在左、相对时间与箭头在右）由 tile 统一；标题兜底、副标题规则
/// 留在各自的薄包装里，因为小说是「读到第几章」、短剧是「看到第几集」。
///
/// 返回普通 Box 而不是 sliver：我的页把内容拆成「头部 / 最近阅读 / 书架」三块，
/// 每块要独立做横向延迟动画，sliver 没法单独平移。
class RecentList<T> extends StatelessWidget {
  const RecentList({super.key, required this.items, required this.tileOf});

  final List<T> items;
  final MineRecentTile Function(T item) tileOf;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            tileOf(items[i]),
          ],
        ],
      ),
    );
  }
}
