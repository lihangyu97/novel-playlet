import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

/// 合并后的推荐流里的一张卡片。
///
/// 三个分类共用同一套分页/网格/搜索骨架，但小说与短剧/漫剧的模型字段不同、
/// 详情页也不同。这里用 sealed class 把"二选一"表达成两种确定的形状：页面和
/// 控制器用 `switch` 取字段，不再有 `novel!.x` / `video!.x` 强转；将来再加
/// 内容类型时，编译器会把所有需要处理新分支的 switch 标出来。
sealed class RecommendItem {
  const RecommendItem();

  String get id;
  String get title;
  String get cover;
  String get intro;

  /// 搜索结果第二行：小说是「作者 · 分类」，短剧/漫剧是「全 N 集」。
  /// 推荐态网格用的是各分类自己的卡片（`NovelGridCard` / `VideoCard`），
  /// 元信息规则不在这一层重复。
  String get searchMeta;
}

/// 小说卡片：保留原始模型给卡片、详情页和 Hero tag 用。
final class NovelRecommendItem extends RecommendItem {
  const NovelRecommendItem(this.novel);

  final NovelItem novel;

  @override
  String get id => novel.id;

  @override
  String get title => novel.title;

  @override
  String get cover => novel.cover;

  @override
  String get intro => novel.intro;

  @override
  String get searchMeta => [
    if (novel.author.isNotEmpty) novel.author,
    if (novel.category.isNotEmpty) novel.category,
  ].join(' · ');
}

/// 短剧/漫剧卡片：保留原始模型给卡片、详情页和 Hero tag 用。
final class VideoRecommendItem extends RecommendItem {
  const VideoRecommendItem(this.video);

  final VideoSeries video;

  @override
  String get id => video.id;

  @override
  String get title => video.title;

  @override
  String get cover => video.cover;

  @override
  String get intro => video.intro;

  @override
  String get searchMeta =>
      video.episodeCount > 0 ? '全 ${video.episodeCount} 集' : '';
}
