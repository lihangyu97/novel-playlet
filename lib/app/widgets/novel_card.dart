import 'package:flutter/material.dart';

import '../../data/models/novel_item.dart';
import 'media_card.dart';

/// 推荐页小说分类的卡片：大封面 + 标题 + 作者/分类。
///
/// 推荐流是混排的（榜单、猜你喜欢、新书），这里用统一的三列网格承载；区块
/// 标题与"更多"留给后续按 cell 渲染，卡片本身不感知区块。
///
/// 骨架与短剧卡完全一致，见 [MediaCard]；这里只负责把 [NovelItem] 映射成
/// 卡片的几个文案参数。
class NovelGridCard extends StatelessWidget {
  const NovelGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 108,
    this.heroTag,
    this.showScore = false,
  });

  final NovelItem item;
  final VoidCallback onTap;
  final double width;

  /// 封面 Hero tag；null = 不参与飞入动画（例如深链/无列表来源）。
  final String? heroTag;

  /// 元信息行是否展示评分（推荐流开启；书架等其它入口保持原名，避免同一张
  /// 卡片在不同页面展示规则不一致）。评分为空 / 0 时不占位。
  final bool showScore;

  @override
  Widget build(BuildContext context) {
    // 作者缺失时退回分类：元信息行不展示空串，但保持占位。
    final head = item.author.isNotEmpty ? item.author : item.category;
    final score = showScore ? scoreLabel(item.score) : '';
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: score.isEmpty ? head : (head.isEmpty ? score : '$head · $score'),
      width: width,
      onTap: onTap,
      heroTag: heroTag,
    );
  }
}

/// 卡片元信息行里的评分文案：上游 `score` 是字符串，`0` / `0.0` / 空都算
/// 未评分；有值时补「分」，避免和集数/字数等纯数字混淆。
String scoreLabel(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value == '0' || value == '0.0') return '';
  return '$value分';
}
