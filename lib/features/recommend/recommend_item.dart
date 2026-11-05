import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

/// 合并后的推荐流里的一张卡片。
///
/// 三个分类共用同一套分页/网格/搜索骨架，但小说与短剧/漫剧的模型字段不同，
/// 详情页也不同。这里只做一层薄包装：保留原始模型给卡片和详情页用（[novel]
/// / [video] 二选一），把两边不一致的展示字段（作者、集数）收敛成
/// [meta] / [searchMeta]。
class RecommendItem {
  const RecommendItem._({this.novel, this.video});

  factory RecommendItem.novel(NovelItem item) => RecommendItem._(novel: item);

  factory RecommendItem.video(VideoSeries item) =>
      RecommendItem._(video: item);

  /// 小说卡片原始模型；短剧/漫剧为 null。
  final NovelItem? novel;

  /// 短剧/漫剧卡片原始模型；小说为 null。
  final VideoSeries? video;

  String get id => novel?.id ?? video!.id;
  String get title => novel?.title ?? video!.title;
  String get cover => novel?.cover ?? video!.cover;
  String get intro => novel?.intro ?? video!.intro;

  /// 搜索结果第二行：小说是「作者 · 分类」，短剧/漫剧是「全 N 集」。
  /// 推荐态网格用的是各分类自己的卡片（`NovelGridCard` / `VideoCard`），
  /// 元信息规则不在这一层重复。
  String get searchMeta {
    final item = novel;
    if (item != null) {
      return [
        if (item.author.isNotEmpty) item.author,
        if (item.category.isNotEmpty) item.category,
      ].join(' · ');
    }
    final series = video!;
    return series.episodeCount > 0 ? '全 ${series.episodeCount} 集' : '';
  }
}
