import '../models/feed_page.dart';
import '../models/json_utils.dart';
import '../models/video_series.dart';
import 'card_walker.dart';

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

/// 短剧链路的下钻 key 白名单（顺序即遍历顺序）。
const _videoChildKeys = [
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
];

/// 短剧卡片的适配口。
///
/// 上游卡片位置不固定（`cell_data` / `video_data[]` /
/// `video_data[].video_detail`），模板卡会把标题/封面放在
/// `video_data[].video_detail` 里，扁平卡直接挂在 `video_data[]` 上；
/// 这里把三层合并成一层再取值，避免两套取值逻辑。
class VideoCardAdapter extends CardAdapter<VideoSeries> {
  const VideoCardAdapter();

  @override
  int get depthLimit => 14;

  @override
  List<String> get childKeys => _videoChildKeys;

  @override
  Iterable<Map<String, dynamic>> candidates(Map<String, dynamic> raw) sync* {
    final videoData = raw['video_data'];
    if (videoData is List && videoData.isNotEmpty) {
      for (final child in videoData) {
        final childMap = asMap(child);
        if (childMap == null) continue;
        final detail = asMap(childMap['video_detail']);
        yield {...raw, ...?detail, ...childMap};
      }
    }
    yield raw;
  }

  @override
  VideoSeries? parse(Map<String, dynamic> raw) {
    final id = firstString(raw, _seriesIdKeys);
    final title = firstString(raw, _seriesTitleKeys);
    if (id.isEmpty || title.isEmpty) return null;
    return VideoSeries(
      id: id,
      title: title,
      cover: firstString(raw, _seriesCoverKeys),
      intro: firstString(raw, _seriesIntroKeys),
      episodeCount: _firstInt(raw, _seriesEpisodeKeys),
      isManju: _isManjuCard(raw),
    );
  }

  @override
  String idOf(VideoSeries card) => card.id;
}

/// 从推荐/搜索响应里递归捞出短剧卡片。
List<VideoSeries> parseVideoSeries(Map<String, dynamic> payload) =>
    walkCards(payload, const VideoCardAdapter());

/// 从搜索响应里只取 `tab_type` 匹配的那个 tab 的短剧/漫剧卡片。
///
/// 搜索接口会一次回多个 `search_tabs`（综合/书籍/漫画/短剧…），直接递归整个
/// 响应会把别的分类的卡片当成本分类（串台）。响应带 `tab_type` 元信息时严格
/// 按分类过滤，没有匹配 tab 就返回空列表（页面按「没有搜索结果」处理）；
/// 老/异形响应完全没有 `tab_type` 时退回整包解析，避免把原本能用的搜索变成
/// 空结果。
List<VideoSeries> parseSearchVideoSeries(
  Map<String, dynamic> payload, {
  required int tabType,
}) {
  final data = asMap(payload['data']) ?? payload;
  final tabs = asList(data['search_tabs'])
      .map(asMap)
      .whereType<Map<String, dynamic>>()
      .toList();
  if (tabs.isEmpty) return const <VideoSeries>[];
  final matched = tabs
      .where((tab) => asInt(tab['tab_type']) == tabType)
      .toList();
  if (matched.isNotEmpty) {
    return parseVideoSeries({
      'data': {'search_tabs': matched},
    });
  }
  final hasTypeInfo = tabs.any((tab) => asInt(tab['tab_type'], 0) > 0);
  if (hasTypeInfo) return const <VideoSeries>[];
  return parseVideoSeries(payload);
}

/// 卡片是否带「漫剧」分类元数据。
///
/// 上游把漫剧混在短剧流/短剧搜索里，只有结构化元数据能证明它是漫剧：
/// `genre=205`，或 `tag_info` / `cover_tag_info_list` / `book_type_name` /
/// `type` 里有「漫剧 / 动态漫 / 动态漫画」。标题、简介里出现「漫剧」只是
/// 提及（比如「漫剧原著」），不能当证据。
bool _isManjuCard(Map<String, dynamic> raw) {
  final book = asMap(raw['book_data']);
  bool matches(Map<String, dynamic>? map) {
    if (map == null) return false;
    if (asInt(map['genre'], -1) == 205) return true;
    for (final key in const [
      'tag_info',
      'cover_tag_info_list',
      'book_type_name',
      'type',
    ]) {
      if (_hasManjuTag(map[key])) return true;
    }
    return false;
  }

  return matches(raw) || matches(book);
}

bool _hasManjuTag(Object? value) {
  if (value is Map) return _hasManjuTag(value['text']);
  if (value is Iterable) return value.any(_hasManjuTag);
  return value is String && const {'漫剧', '动态漫', '动态漫画'}.contains(value.trim());
}

/// 解析漫剧搜索/翻页兜底的一页。
///
/// 上游没有独立的漫剧搜索 tab：漫剧卡片混在短剧搜索 tab（`tab_type=11`）
/// 里，必须按卡片的漫剧元数据过滤，否则会把普通短剧画进漫剧分类。游标挂在
/// 短剧 tab 的 `next_offset` / `has_more` 上（漫剧首页流 `tab_type=24` 没有
/// 游标，后续页只能走这里）。
FeedPage<VideoSeries> parseManjuSearchPage(
  Map<String, dynamic> payload, {
  required int offset,
}) {
  final data = asMap(payload['data']) ?? payload;
  final tabs = asList(data['search_tabs'])
      .map(asMap)
      .whereType<Map<String, dynamic>>()
      .toList();
  final sources = tabs.where((tab) {
    final type = asInt(tab['tab_type'], 0);
    if (type == 11) return true;
    // 老/异形响应没有 tab_type：短剧搜索桶的标题是「短剧」。
    if (type == 0) {
      final title = asString(tab['title']);
      return title.contains('短剧') || title.contains('漫剧');
    }
    return false;
  }).toList();

  final items = <VideoSeries>[];
  final seen = <String>{};
  for (final tab in sources) {
    for (final item in parseVideoSeries({
      'data': {
        'search_tabs': [tab],
      },
    })) {
      if (!item.isManju) continue;
      if (seen.add(item.id)) items.add(item);
    }
  }

  int? nextOffset;
  for (final tab in sources) {
    final next = asInt(tab['next_offset'], -1);
    if (next > offset && _allowsMore(tab['has_more'])) {
      nextOffset = next;
      break;
    }
  }
  // 上游没给游标却声明还有更多：按每页 10 条推进（fqapp 的同款兼容，
  // 漫剧/漫画的搜索游标偶尔缺失）。
  if (nextOffset == null &&
      items.isNotEmpty &&
      sources.any((tab) => tab['has_more'] == true)) {
    nextOffset = offset + 10;
  }
  return FeedPage<VideoSeries>(items: items, nextOffset: nextOffset);
}

bool _allowsMore(Object? hasMore) =>
    hasMore != false && hasMore != 'false' && hasMore != 0;

int _firstInt(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = asInt(map[key], -1);
    if (value > 0) return value;
  }
  return 0;
}
