import 'package:flutter/material.dart';

import '../../../app/widgets/novel_card.dart';
import '../../../data/models/novel_item.dart';

/// 搜索结果列表（sliver 形态）：复用共享的横向卡片，行间细分隔线。
class RecommendResultsSliver extends StatelessWidget {
  const RecommendResultsSliver({
    super.key,
    required this.items,
    required this.onTap,
  });

  final List<NovelItem> items;
  final ValueChanged<NovelItem> onTap;

  @override
  Widget build(BuildContext context) {
    return SliverList.separated(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return NovelListTile(item: item, onTap: () => onTap(item));
      },
      separatorBuilder: (context, index) =>
          const Divider(indent: 94, endIndent: 16),
    );
  }
}
