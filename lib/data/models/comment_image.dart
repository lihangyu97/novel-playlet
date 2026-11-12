import 'json_utils.dart';

/// 评论配图的一张图：缩略图与原图两个地址。
///
/// 缩略图给列表里的缩略图格位（几十 pt），原图给全屏查看器。上游多数条目
/// 只给 `web_url`，这时 [thumb] 与 [full] 相同；有 `thumb_url` 时优先用它，
/// 避免几十 pt 的格子去下原图（CDN 原图常是 1080 宽以上）。
///
/// [full] 为空表示这条无效；[thumb] 允许等于 [full]（上游没给缩略图时），
/// 解析器不产出 thumb 为空的条目。
class CommentImageRef {
  const CommentImageRef({required this.thumb, required this.full});

  /// 缩略图地址（可等于 [full]；上游没给 `thumb_url` 时退回原图）。
  final String thumb;

  /// 原图地址（全屏查看器用）。
  final String full;

  bool get isEmpty => full.isEmpty && thumb.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is CommentImageRef && other.thumb == thumb && other.full == full;

  @override
  int get hashCode => Object.hash(thumb, full);

  @override
  String toString() => 'CommentImageRef(thumb: $thumb, full: $full)';
}

/// 解析评论配图列表，同时保留缩略图与原图地址。
///
/// 段评/书评/短剧评论共用同一个上游字段：
/// `content.image_data_list.image_data[].web_url`。有些源会把列表直接给成
/// 数组，或者字段名只给 `url` / `thumb_url`，这里都兼容。
///
/// 同一条评论里同一张图偶尔会重复出现（`web_url` 与 `url` 相同），按原图
/// 地址去重，UI 只画一次。
List<CommentImageRef> parseCommentImageRefs(Object? raw) {
  final container = asMap(raw);
  final list = asList(container?['image_data'] ?? raw);
  final refs = <CommentImageRef>[];
  final seenFull = <String>{};
  for (final entry in list) {
    final map = asMap(entry);
    if (map == null) continue;
    // 原图优先 web_url（与旧实现一致，查看器要最大的一张）；缩略图优先
    // thumb_url，缺失时退回原图。
    final full = normalizeCommentImageUrl(
      firstString(map, ['web_url', 'url', 'thumb_url']),
    );
    if (full.isEmpty || !seenFull.add(full)) continue;
    final thumbRaw = normalizeCommentImageUrl(
      firstString(map, ['thumb_url', 'web_url', 'url']),
    );
    refs.add(
      CommentImageRef(thumb: thumbRaw.isEmpty ? full : thumbRaw, full: full),
    );
  }
  return List<CommentImageRef>.unmodifiable(refs);
}

/// 评论配图的原图 URL 列表（兼容旧调用；新代码用 [parseCommentImageRefs]）。
List<String> parseCommentImages(Object? raw) {
  return List<String>.unmodifiable([
    for (final ref in parseCommentImageRefs(raw)) ref.full,
  ]);
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
