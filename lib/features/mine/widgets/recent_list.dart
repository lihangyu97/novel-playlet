import 'package:flutter/material.dart';

import 'mine_recent_tile.dart';

/// 「最近阅读 / 最近观看」共用的列表骨架：逐条渲染 [MineRecentTile]。
///
/// 版式（封面在左、相对时间与箭头在右）由 tile 统一；标题兜底、副标题规则
/// 留在各自的薄包装里，因为小说是「读到第几章」、短剧是「看到第几集」。
///
/// 返回普通 Box：作为 [SliverToBoxAdapter] 的内容使用，列表本身不单独滚动。
///
/// 行与行之间不留额外 gap：每条 tile 自己上下各 8pt 内边距，相邻行之间自然
/// 是 16pt，与区块/网格的 8 留白同一套节奏。
class RecentList<T> extends StatelessWidget {
  const RecentList({super.key, required this.items, required this.tileOf});

  final List<T> items;
  final MineRecentTile Function(T item) tileOf;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [for (var i = 0; i < items.length; i++) tileOf(items[i])],
      ),
    );
  }
}
