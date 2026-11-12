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
    final url = normalizeCommentImageUrl(
      firstString(map, ['web_url', 'url', 'thumb_url']),
    );
    // 同一张图偶尔会在 web_url / url 里重复出现，去重后 UI 只画一次。
    if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
  }
  return List<String>.unmodifiable(urls);
}

/// 把上游图片地址归一成可直接加载的绝对 URL。
///
/// 上游多数是 `https://p3-sign.douyinpic.com/...`，但兼容两种脏数据：
///   - 协议相对地址 `//host/path`（补成 https，iOS ATS 只允许 https）；
///   - JSON 里漏转义的 `&amp;`（图片 CDN 的签名参数常带 `&`）。
/// 非法/非 http(s)/没有 host 的地址直接丢弃，避免把非法 URL 交给 ImageProvider
/// 触发整条评论渲染异常。
String normalizeCommentImageUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return '';
  url = url.replaceAll('&amp;', '&');
  if (url.startsWith('//')) url = 'https:$url';
  final uri = Uri.tryParse(url);
  if (uri == null) return '';
  if (uri.scheme != 'http' && uri.scheme != 'https') return '';
  if (uri.host.isEmpty) return '';
  return url;
}
