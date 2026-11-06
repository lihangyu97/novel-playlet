import 'package:flutter/material.dart';

import 'content_source.dart';

/// 「推荐」页搜索框下方的一级分类。
///
/// 这个 enum 只放展示信息（标签、搜索框提示、空态图标）和取数策略
/// [source]；上游 `tab_type`、搜索 tab、漫剧兜底这些请求差异都在
/// [ContentSource] 的实现里，不再挂在枚举上。
enum RecommendCategory {
  novel(
    label: '小说',
    searchHint: '搜索书名/作者',
    emptyIcon: Icons.auto_stories_outlined,
    source: NovelSource(),
  ),
  drama(
    label: '短剧',
    searchHint: '搜索短剧',
    emptyIcon: Icons.movie_outlined,
    source: DramaSource(),
  ),
  anime(
    label: '漫剧',
    searchHint: '搜索漫剧',
    emptyIcon: Icons.auto_awesome_motion_outlined,
    source: ManjuSource(),
  );

  const RecommendCategory({
    required this.label,
    required this.searchHint,
    required this.emptyIcon,
    required this.source,
  });

  final String label;
  final String searchHint;
  final IconData emptyIcon;

  /// 这个分类的推荐流/搜索怎么向上游要数据。
  final ContentSource source;
}
