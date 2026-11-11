import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

/// 推荐流/搜索结果里的一张卡片。
///
/// 三个分类共用同一套分页/卡片骨架，但小说与短剧/漫剧的模型字段不同、详情页
/// 也不同。这里用 sealed class 把"二选一"表达成两种确定的形状：页面和控制器用
/// `switch` 取字段，不再有 `novel!.x` / `video!.x` 强转；将来再加内容类型时，
/// 编译器会把所有需要处理新分支的 switch 标出来。
///
/// 只保留跨类型通用的 [id]（去重、Hero tag 用）；标题/封面/元信息都交给各自
/// 的卡片组件从具体模型里取。
sealed class RecommendItem {
  const RecommendItem();

  String get id;
}

/// 小说卡片：保留原始模型给卡片、详情页和 Hero tag 用。
final class NovelRecommendItem extends RecommendItem {
  const NovelRecommendItem(this.novel);

  final NovelItem novel;

  @override
  String get id => novel.id;
}

/// 短剧/漫剧卡片：保留原始模型给卡片、详情页和 Hero tag 用。
final class VideoRecommendItem extends RecommendItem {
  const VideoRecommendItem(this.video);

  final VideoSeries video;

  @override
  String get id => video.id;
}
