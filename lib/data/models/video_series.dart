import 'json_utils.dart';

/// 视频 tab 列表/搜索结果里的一部短剧。
///
/// 上游把短剧卡片放在 `video_data` / `video_detail` 的不同层级，字段名也与
/// 小说不同（`series_title`/`series_cover`/`episode_cnt`），所以单独建模型，
/// 不复用 NovelItem 的 `book_id` 语义——短剧的 `video_id` 不是书 id。
/// 卡片解析在 `data/parsers/video_parsers.dart`。
class VideoSeries {
  const VideoSeries({
    required this.id,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.isManju = false,
    this.score = '',
    this.recommendReason = '',
    this.rankScore = '',
    this.colorDominate = '',
  });

  /// 剧集 id（`series_id_str` 优先：数字型 `series_id` 会被上游截断）。
  final String id;
  final String title;
  final String cover;
  final String intro;
  final int episodeCount;

  /// 卡片元数据是否标明这是漫剧（`genre=205` / 「漫剧、动态漫画」标签）。
  /// 漫剧首页流 `tab_type=24` 整条都是漫剧，不依赖这个字段；只有混在短剧
  /// 搜索流里的卡片要靠它区分。
  final bool isManju;

  /// 评分（上游 `score`，如「8.2」）。
  final String score;

  /// 推荐理由（`recommend_reason_list` JSON 串里第一条可展示文案）。
  final String recommendReason;

  /// 热度（`rec_text`，如「4691万热度」），短剧没有 `rank_score`，用它对位。
  final String rankScore;

  /// 封面主色（上游 `color_dominate` / `back_color_dominate`，如 `#201818`）；
  /// 短剧 payload 里这个字段还没在抓包样本里确认过，有就用于封面占位色，
  /// 没有则退回系统灰。
  final String colorDominate;

  bool get isValid => id.isNotEmpty && title.isNotEmpty;

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'intro': intro,
    if (episodeCount > 0) 'episodeCount': episodeCount,
    if (colorDominate.isNotEmpty) 'colorDominate': colorDominate,
  };

  static VideoSeries fromStorageJson(Map<String, dynamic> json) => VideoSeries(
    id: asString(json['id']),
    title: asString(json['title']),
    cover: asString(json['cover']),
    intro: asString(json['intro']),
    episodeCount: asInt(json['episodeCount']),
    colorDominate: asString(json['colorDominate']),
  );

  /// 按"所有参与展示的字段"比较，不是只比 id：
  /// 短剧/漫剧会同时出现在首页流、搜索兜底和收藏里，同一部剧的封面、简介、
  /// 集数可能晚到或缺失，只比 id 会让 diff / select 漏掉这些更新；收藏/进度
  /// 按 id 去重由调用方显式用 [id]。
  @override
  bool operator ==(Object other) =>
      other is VideoSeries &&
      other.id == id &&
      other.title == title &&
      other.cover == cover &&
      other.intro == intro &&
      other.episodeCount == episodeCount &&
      other.isManju == isManju &&
      other.score == score &&
      other.recommendReason == recommendReason &&
      other.rankScore == rankScore &&
      other.colorDominate == colorDominate;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    cover,
    intro,
    episodeCount,
    isManju,
    score,
    recommendReason,
    rankScore,
    colorDominate,
  );
}
