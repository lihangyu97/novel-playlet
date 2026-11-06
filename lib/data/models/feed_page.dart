/// 上游分页接口的一页（推荐流 / 搜索 / 短剧 / 漫剧共用）。
///
/// 推荐与搜索的游标语义一致：游标不前进就视为到底，[hasMore] 只认
/// [nextOffset]。推荐流（短剧/漫剧）翻页必须回传同一个 [sessionId]，搜索为 null。
class FeedPage<T> {
  const FeedPage({required this.items, this.nextOffset, this.sessionId});

  final List<T> items;

  /// 下一页游标；null 表示到底。
  final int? nextOffset;

  /// 推荐流的会话 id。只对推荐流有意义，搜索恒为 null。
  final String? sessionId;

  bool get hasMore => nextOffset != null && nextOffset! > 0;

  @override
  bool operator ==(Object other) =>
      other is FeedPage<T> &&
      _sameItems(other.items, items) &&
      other.nextOffset == nextOffset &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), nextOffset, sessionId);
}

/// 手写列表相等（数据层不依赖 flutter/foundation，也不引第三方包）。
bool _sameItems<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
