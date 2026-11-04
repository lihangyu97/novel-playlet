import 'json_utils.dart';

/// 短剧详情（`/api/v1/series/{id}`）。
///
/// 上游把剧集信息放在 `data.video_data`，字段名与小说详情完全不同
/// （`series_title`/`series_cover`/`series_intro`/`episode_cnt`）。这里只取
/// 详情页真正要展示的字段，演员表/评论等留给后续。
class VideoDetail {
  const VideoDetail({
    this.id = '',
    this.title = '',
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.categories = const [],
    this.playCount = 0,
    this.followerCount = 0,
  });

  final String id;
  final String title;
  final String cover;
  final String intro;
  final int episodeCount;
  final List<String> categories;
  final int playCount;
  final int followerCount;

  bool get isEmpty => title.isEmpty && cover.isEmpty;

  static const VideoDetail empty = VideoDetail();

  /// 解析剧集详情。业务失败（`code != 0/200`）返回 [empty]，由页面决定是
  /// 展示空态还是重试——详情只是播放的入口，不该因为装饰性字段失败卡死。
  factory VideoDetail.fromPayload(Map<String, dynamic> payload) {
    final code = asInt(payload['code'], 0);
    if (code != 0 && code != 200) return empty;
    final data = asMap(payload['data']);
    if (data == null) return empty;
    final video = asMap(data['video_data']);
    if (video == null) return empty;

    return VideoDetail(
      id: firstString(video, ['series_id_str', 'series_id']),
      title: firstString(video, ['series_title', 'series_name']),
      cover: firstString(video, ['series_cover', 'cover', 'thumb_url']),
      intro: firstString(video, ['series_intro', 'intro', 'abstract']),
      episodeCount: asInt(video['episode_cnt']),
      categories: _categoryNames(video['category_schema']),
      playCount: asInt(video['series_play_cnt']),
      followerCount: asInt(video['followed_cnt']),
    );
  }
}

/// `category_schema` 是一段内嵌 JSON（形如 `[{"name":"都市"},...]`），也
/// 可能是逗号分隔的纯文本；两种都兼容，取不到就返回空表。
List<String> _categoryNames(Object? raw) {
  final text = asString(raw).trim();
  if (text.isEmpty) return const [];
  final names = <String>[];
  for (final match in RegExp(r'"name"\s*:\s*"([^"]+)"').allMatches(text)) {
    final name = match.group(1)?.trim() ?? '';
    if (name.isNotEmpty) names.add(name);
  }
  if (names.isNotEmpty) return names;
  return text
      .split(RegExp(r'[,，]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}
