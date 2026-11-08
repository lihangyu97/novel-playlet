import 'json_utils.dart';

/// 评论配图 URL。
///
/// 段评/书评/短剧评论共用同一个上游字段：
/// `content.image_data_list.image_data[].web_url`。有些源会把列表直接给成
/// 数组，或者字段名只给 `url`，这里都兼容，读不到就当没有图。
List<String> parseCommentImages(Object? raw) {
  final container = asMap(raw);
  final list = asList(container?['image_data'] ?? raw);
  final urls = <String>[];
  for (final entry in list) {
    final map = asMap(entry);
    if (map == null) continue;
    final url = firstString(map, ['web_url', 'url', 'thumb_url']);
    if (url.isNotEmpty) urls.add(url);
  }
  return List<String>.unmodifiable(urls);
}
