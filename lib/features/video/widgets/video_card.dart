import 'package:flutter/material.dart';

import '../../../app/widgets/media_card.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../data/models/video_series.dart';

/// 视频列表的卡片：竖版封面 + 标题 + 集数。
///
/// 与小说卡片的区别只在元信息：短剧/漫剧没有作者，展示「全 N 集」，缺集数
/// 时不硬凑一行（避免出现空字符串占位）。骨架见 [MediaCard]。
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
    this.heroTag,
    this.showRecommendMeta = false,
    this.reasonOnCover = false,
    this.showReason = true,
    this.coverAspect = kCoverAspect,
    this.surface = false,
    this.naturalTitleHeight = false,
  });

  final VideoSeries item;
  final double width;
  final VoidCallback onTap;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String? heroTag;

  /// 元信息是否按推荐流规则展示（推荐流开启；书架等入口保持「全 N 集」）。
  ///
  /// 集数固定占元信息行；推荐流再把 `recommend_reason_list` 第一条与
  /// 热度（短剧用 `rec_text`）**有就显示**，摆放见 [reasonOnCover]。
  final bool showRecommendMeta;

  /// 推荐理由是否放封面左上角角标。
  ///
  /// 双列时开启：理由上封面、热度（`rec_text`）右对齐到集数同一行；三列
  /// 太窄，退回文字区独立一行。
  final bool reasonOnCover;

  /// 是否展示推荐理由（`recommend_reason_list`）。
  ///
  /// 搜索页关掉：上游会把分类名塞进理由（如「漫剧」），和这一行的分类标题
  /// 重复；关掉只影响理由，热度照常展示。
  final bool showReason;

  /// 封面高 / 宽；推荐流传 [kVideoCoverAspect]，其它入口保持默认。
  final double coverAspect;

  /// 是否画成白底卡片（见 [MediaCard.surface]）。
  final bool surface;

  /// 标题是否按内容自然高度（见 [MediaCard.naturalTitleHeight]）。
  final bool naturalTitleHeight;

  @override
  Widget build(BuildContext context) {
    return MediaCard(
      cover: item.cover,
      title: item.title,
      meta: _episodesOf(),
      // 双列：理由上封面角标、热度右对齐到集数行尾。
      coverBadge: reasonOnCover && showReason ? _reasonOf() : null,
      metaTrailing: reasonOnCover ? _heatOf() : null,
      // 三列：理由/热度各自一行，有就显示。
      extraMeta: reasonOnCover ? const [] : _extraMetaOf(),
      // 封面占位色用上游主色（`color_dominate`），加载过程不闪灰块。
      coverPlaceholderColor: coverPlaceholderColorOf(item.colorDominate),
      // 评分和小说一致：移到封面右上角角标，不占元信息行。
      cornerText: showRecommendMeta ? scoreLabel(item.score) : null,
      width: width,
      onTap: onTap,
      heroTag: heroTag,
      coverAspect: coverAspect,
      surface: surface,
      naturalTitleHeight: naturalTitleHeight,
    );
  }

  /// 元信息行：有集数才有这一行（缺集数不硬凑空行）。
  String? _episodesOf() =>
      item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : null;

  String _reasonOf() => showRecommendMeta ? item.recommendReason : '';

  String _heatOf() => showRecommendMeta ? item.rankScore : '';

  /// 三列时的可选字段：推荐理由 / 热度各一行，有就显示；书架等入口不传。
  List<String> _extraMetaOf() {
    if (!showRecommendMeta) return const [];
    return [
      if (showReason && item.recommendReason.isNotEmpty) item.recommendReason,
      if (item.rankScore.isNotEmpty) item.rankScore,
    ];
  }
}
