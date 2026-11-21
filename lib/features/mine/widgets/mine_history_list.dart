import 'package:flutter/material.dart';

import '../../../core/storage/library_records.dart';
import '../mine_record_copy.dart';
import 'library_type_badge.dart';
import 'mine_recent_tile.dart';
import 'recent_list.dart';

/// 「历史」列表：小说与短剧混排，一条时间线。
///
/// 副标题前挂「小说 / 短剧」彩色标签，进度文案按类型分派：
/// 小说「读到第 N 章」、短剧「看到第 N 集」。
class MineHistoryList extends StatelessWidget {
  const MineHistoryList({super.key, required this.items, required this.onOpen});

  final List<LibraryRecord> items;
  final ValueChanged<LibraryRecord> onOpen;

  @override
  Widget build(BuildContext context) {
    return RecentList<LibraryRecord>(
      items: items,
      tileOf: (item) => MineRecentTile(
        cover: item.cover,
        title: item.title.isEmpty ? '未命名作品' : item.title,
        label: LibraryTypeBadge(type: item.type),
        subtitle: mineHistorySubtitle(item),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(item.lastReadAt),
        onTap: () => onOpen(item),
      ),
    );
  }
}
