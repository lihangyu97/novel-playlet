import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../app/widgets/card_flight_route.dart';
import '../../app/widgets/cover_hero.dart';
import '../../data/models/rank.dart';

/// 榜单条目 → 详情路由 / Hero tag。
///
/// 排行榜页与首页榜单预览卡点击行为的唯一来源：按 `book_data` / `video_data`
/// 分派到小说或短剧详情，Hero tag 带上「来源榜」，同一页面里多个榜的同一本书
/// 不会撞 tag。
AppRoute<void> rankEntryRoute(
  RankEntry entry,
  String source, {
  CardRectResolver? cardSource,
}) {
  return entry.isVideo
      ? VideoDetailRoute(
          seriesId: entry.id,
          preview: entry.toVideoSeries(),
          heroTag: rankEntryHeroTag(entry, source),
        )
      : DetailRoute(
          bookId: entry.id,
          preview: entry.toNovelItem(),
          heroTag: rankEntryHeroTag(entry, source),
        );
}

/// 榜单封面 Hero tag：`cover-{kind}-{source}-{id}`。
String rankEntryHeroTag(RankEntry entry, String source) => entry.isVideo
    ? CoverHeroTag.video(source, entry.id)
    : CoverHeroTag.novel(source, entry.id);

/// 打开榜单条目详情；空条目（接口缺 id/标题）不跳。
void openRankEntry(
  BuildContext context,
  RankEntry entry, {
  required String source,
  CardRectResolver? cardSource,
}) {
  if (entry.isEmpty) return;
  context.pushAppRoute(rankEntryRoute(entry, source, cardSource: cardSource));
}
