import 'json_utils.dart';

/// 视频 tab 列表/搜索结果里的一部短剧。
///
/// 上游把短剧卡片放在 `video_data` / `video_detail` 的不同层级，字段名也与
/// 小说不同（`series_title`/`series_cover`/`episode_cnt`），所以单独建模型，
/// 不复用 [NovelItem] 的 `book_id` 语义——短剧的 `video_id` 不是书 id。
class VideoSeries {
  const VideoSeries({
    required this.id,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
  });

  /// 剧集 id（`series_id_str` 优先：数字型 `series_id` 会被上游截断）。
  final String id;
  final String title;
  final String cover;
  final String intro;
  final int episodeCount;

  bool get isValid => id.isNotEmpty && title.isNotEmpty;
}

/// 视频列表的一页。[nextOffset] 为 null 表示到底。
class VideoFeedPage {
  const VideoFeedPage({
    required this.items,
    this.nextOffset,
    this.sessionId,
  });

  final List<VideoSeries> items;
  final int? nextOffset;

  /// 推荐流翻页必须回传同一个 session（上游否则会换设备）；搜索为 null。
  final String? sessionId;

  bool get hasMore => nextOffset != null && nextOffset! > 0;
}

/// 短剧卡片的身份字段。`series_id` 系列优先，兼容漫剧的 `pseries_id` 和
/// 单集卡片上的 `video_id`（feed 里两者都会出现）。
const _seriesIdKeys = ['series_id_str', 'series_id', 'pseries_id', 'video_id'];

const _seriesTitleKeys = [
  'series_title',
  'series_name',
  'video_name',
  'title',
  'name',
  'book_name',
];

const _seriesCoverKeys = [
  'series_cover',
  'cover',
  'thumb_url',
  'cover_url',
  'detail_page_thumb_url',
  'image_url',
];

const _seriesIntroKeys = [
  'series_intro',
  'intro',
  'abstract',
  'description',
  'summary',
];

const _seriesEpisodeKeys = [
  'episode_cnt',
  'episode_count',
  'total_episode',
  'total_video_cnt',
  'video_count',
  'episode_num',
];

/// 从推荐/搜索响应里递归捞出短剧卡片。
///
/// 上游卡片位置不固定（`cell_data` / `video_data[]` / `video_data[].video_detail`），
/// 所以按「父层字段 + detail 字段 + 卡片字段」三层合并后再取值；只认短剧
/// 自己的 id 字段，因此同一响应里混排的小说/漫画卡不会被误收。
List<VideoSeries> parseVideoSeries(Map<String, dynamic> payload) {
  final root = asMap(payload['data']) ?? payload;
  final out = <VideoSeries>[];
  final seen = <String>{};

  void add(Map<String, dynamic> raw) {
    final id = firstString(raw, _seriesIdKeys);
    final title = firstString(raw, _seriesTitleKeys);
    if (id.isEmpty || title.isEmpty) return;
    if (!seen.add(id)) return;
    out.add(
      VideoSeries(
        id: id,
        title: title,
        cover: firstString(raw, _seriesCoverKeys),
        intro: firstString(raw, _seriesIntroKeys),
        episodeCount: _firstInt(raw, _seriesEpisodeKeys),
      ),
    );
  }

  void visit(Object? value, int depth) {
    if (depth > 14 || value == null) return;
    if (value is List) {
      for (final child in value) {
        visit(child, depth + 1);
      }
      return;
    }
    final map = asMap(value);
    if (map == null) return;

    // 模板卡把标题/封面放在 `video_data[].video_detail`，扁平卡直接挂在
    // `video_data[]` 上；合并成一层，避免两套取值逻辑。
    final videoData = map['video_data'];
    if (videoData is List && videoData.isNotEmpty) {
      for (final child in videoData) {
        final childMap = asMap(child);
        if (childMap == null) continue;
        final detail = asMap(childMap['video_detail']);
        add({
          ...map,
          ...?detail,
          ...childMap,
        });
      }
    }

    add(map);

    for (final key in const [
      'tab_item',
      'cell_data',
      'cell_view',
      'video_data',
      'video_detail',
      'book_data',
      'search_tabs',
      'items',
      'lists',
      'item_data_list',
      'recommend_list',
      'data',
    ]) {
      if (map.containsKey(key)) visit(map[key], depth + 1);
    }
  }

  visit(root, 0);
  return out;
}

int _firstInt(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = asInt(map[key], -1);
    if (value > 0) return value;
  }
  return 0;
}
