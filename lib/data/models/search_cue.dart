import 'json_utils.dart';

/// 搜索框轮播热词（cue）。
///
/// 上游 `/reading/bookapi/search/cue/v` 一次返回**一整组**词（`data_v1[]`），
/// 外加轮播间隔 `rotate_interval_ms`；官方搜索框是一次只显示一条、由客户端
/// 自己按时轮播（`SearchWordDisplayView` 的 `VerticalFlipper`），不是一条条
/// 请求。这里只做解析：一条词都没有就返回 [empty]，搜索框回退静态提示语。
class SearchCue {
  const SearchCue({
    this.words = const [],
    this.rotateIntervalMs = defaultIntervalMs,
  });

  /// 没有 `rotate_interval_ms` 时用的轮播间隔（官方默认 5s）。
  static const defaultIntervalMs = 5000;

  static const empty = SearchCue();

  final List<String> words;

  /// 一条词在占位里停留多久再翻下一条。
  final int rotateIntervalMs;

  bool get isEmpty => words.isEmpty;
  bool get isNotEmpty => words.isNotEmpty;

  /// 解析搜索框热词响应。
  ///
  /// 展示文案优先 `display_text_v2` → `display_text` → `text`（官方
  /// `SearchCueWord` 的取值顺序）；空词与重复词跳过——空 cell 在真实响应里
  /// 存在，不能铺成空占位。
  static SearchCue fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final words = <String>[];
    final seen = <String>{};
    for (final entry in asList(payload['data_v1'])) {
      final map = asMap(entry);
      if (map == null) continue;
      final text = _displayText(map);
      if (text.isEmpty || !seen.add(text)) continue;
      words.add(text);
    }
    if (words.isEmpty) return empty;
    final interval = asInt(payload['rotate_interval_ms'], defaultIntervalMs);
    return SearchCue(
      words: List.unmodifiable(words),
      rotateIntervalMs: interval > 0 ? interval : defaultIntervalMs,
    );
  }

  static String _displayText(Map<String, dynamic> entry) {
    for (final key in const ['display_text_v2', 'display_text', 'text']) {
      final text = asString(entry[key]).trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
