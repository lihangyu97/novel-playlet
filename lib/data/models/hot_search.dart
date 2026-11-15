import 'json_utils.dart';

/// 热搜榜里的一条。
///
/// 上游是番茄「热搜榜」（`/reading/bookapi/search/rank_list/v:version/`，
/// `show_type=472`）：一个 cell 里最多 50 条 tag，每条带 `tag_title`、
/// `tag_attached`（「热门讨论·39054552热搜值」这类热度文案，线上常带编辑前缀）和 `display_tag`
///（巅峰榜 / 热聊 / 新 这些角标）。这里只保留展示需要的字段。
class HotSearchEntry {
  const HotSearchEntry({
    required this.title,
    this.hotPrefix = '',
    this.hotValue = '',
    this.badge,
  });

  /// 可点的搜索词（`tag_title`）。
  final String title;

  /// `tag_attached` 里热搜值前面的编辑前缀，原样保留（通常以「·」结尾），
  /// 如 `热门讨论·` / `巅峰榜NO.3·`；没有前缀时为空。
  final String hotPrefix;

  /// 热搜值原文（去掉「热搜值」后缀和编辑前缀），如 `39054552` / `183.8万`；
  /// 上游放的是编辑文案时为空。
  final String hotValue;

  /// 榜单角标（`display_tag` 的第一项），没有则为 null。
  final HotSearchBadge? badge;

  bool get isEmpty => title.isEmpty;

  /// 榜单右侧展示文案：保留上游前缀，只把数字换算成整数 w+。
  ///
  /// 例：`热门讨论·39054552热搜值` → `热门讨论·3905w+`；
  /// `3048111热搜值` → `305w+`。
  String get hotLabel {
    final formatted = formatHotSearchValue(hotValue);
    if (formatted.isEmpty) return '';
    return '$hotPrefix$formatted';
  }
}

/// 榜单角标：`display_tag[]` 的一项。
///
/// 上游给文字 + 明暗两套渐变颜色。颜色是 `#RRGGBBAA`（业务色 + 透明度），
/// 这里统一转成 Flutter 的 ARGB int（`AARRGGBB`），UI 直接 `Color(value)`；
/// 空列表表示上游没给颜色，由 UI 走主题色兜底。
class HotSearchBadge {
  const HotSearchBadge({
    required this.text,
    this.lightTextColors = const [],
    this.darkTextColors = const [],
    this.lightBackgroundColors = const [],
    this.darkBackgroundColors = const [],
  });

  final String text;
  final List<int> lightTextColors;
  final List<int> darkTextColors;
  final List<int> lightBackgroundColors;
  final List<int> darkBackgroundColors;

  bool get isEmpty => text.isEmpty;
}

/// 热搜榜。
///
/// 上游把 tag 放在 `data[].search_tag_data[]` 里，且 `data` 可能夹着没有
/// tag 的 cell；空 cell / 重复词直接跳过，避免页面出现空行或重复条目。
class HotSearch {
  const HotSearch({this.entries = const []});

  static const empty = HotSearch();

  final List<HotSearchEntry> entries;

  List<String> get words => [for (final entry in entries) entry.title];

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  static HotSearch fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && asInt(code, -1) != 0 && asInt(code, -1) != 200) {
      return empty;
    }
    final entries = <HotSearchEntry>[];
    final seen = <String>{};
    for (final cell in asList(payload['data'])) {
      final map = asMap(cell);
      if (map == null) continue;
      for (final rawTag in asList(map['search_tag_data'])) {
        final tag = asMap(rawTag);
        if (tag == null) continue;
        final title = asString(tag['tag_title']).trim();
        if (title.isEmpty || !seen.add(title)) continue;
        final hot = _splitAttached(tag['tag_attached']);
        entries.add(
          HotSearchEntry(
            title: title,
            hotPrefix: hot.prefix,
            hotValue: hot.value,
            badge: _badge(tag['display_tag']),
          ),
        );
      }
    }
    return HotSearch(entries: List.unmodifiable(entries));
  }

  /// 拆分 `tag_attached`：去掉「热搜值」后缀，数字与前缀分开返回。
  ///
  /// 线上形态不是纯数字：热搜值前面可能带一段编辑前缀（热门讨论 / 热度飙升 /
  /// 巅峰榜NO.3 / “细糠” …），通常用「·」隔开。前缀原样保留给 UI 展示，数字
  /// 单独交给 [formatHotSearchValue] 换算成 w+；没有「热搜值」后缀的编辑文案
  /// 直接丢弃，不硬凑数字。
  static ({String prefix, String value}) _splitAttached(Object? attached) {
    final text = asString(attached).trim();
    if (!text.endsWith('热搜值')) return (prefix: '', value: '');
    final withoutSuffix = text.substring(0, text.length - 3).trim();
    final match = _hotValueTailPattern.firstMatch(withoutSuffix);
    if (match == null) return (prefix: '', value: '');
    return (
      prefix: withoutSuffix.substring(0, match.start).trim(),
      value: '${match.group(1)}${match.group(2) ?? ''}',
    );
  }

  static HotSearchBadge? _badge(Object? displayTag) {
    for (final raw in asList(displayTag)) {
      final map = asMap(raw);
      if (map == null) continue;
      final text = asString(map['text']).trim();
      if (text.isEmpty) continue;
      return HotSearchBadge(
        text: text,
        lightTextColors: _colors(map['text_gradient_color'], 'light'),
        darkTextColors: _colors(map['text_gradient_color'], 'dark'),
        lightBackgroundColors: _colors(map['bg_gradient_color'], 'light'),
        darkBackgroundColors: _colors(map['bg_gradient_color'], 'dark'),
      );
    }
    return null;
  }

  static List<int> _colors(Object? raw, String mode) {
    final map = asMap(raw);
    if (map == null) return const [];
    final colors = <int>[];
    for (final value in asList(map[mode])) {
      final color = _argb(asString(value));
      if (color != null) colors.add(color);
    }
    return List.unmodifiable(colors);
  }

  /// `#FA67251A`（RRGGBBAA）-> `0x1AFA6725`（AARRGGBB）；`#FA6725` -> 不透明。
  static int? _argb(String raw) {
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 8) {
      hex = '${hex.substring(6, 8)}${hex.substring(0, 6)}';
    } else if (hex.length == 6) {
      hex = 'FF$hex';
    } else {
      return null;
    }
    return int.tryParse(hex, radix: 16);
  }
}

/// `tag_attached` 末尾的热度数字：`热门讨论·39054552` -> `39054552`，
/// `巅峰榜NO.3·5562896` -> `5562896`，`183.8万` -> `183.8万`。
final _hotValueTailPattern = RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*(亿|万)?\s*$');

/// `183.8万` -> `184w+`，`1.2亿` -> `12000w+`，裸数字按原始计数换算成 w
///（`39054552` -> `3905w+`；线上当前就是这种裸数字）。
///
/// 只输出整数（四舍五入，不留小数点）；解析不出数字（编辑文案）时返回空串，
/// 不硬凑一个 0。
String formatHotSearchValue(String raw) {
  var text = raw.trim();
  // 直接拿上游 `tag_attached` 原文调用也成立（解析层通常已经去掉后缀）。
  if (text.endsWith('热搜值')) {
    text = text.substring(0, text.length - 3).trim();
  }
  final match = _hotValueTailPattern.firstMatch(text);
  if (match == null) return '';
  final number = double.tryParse(match.group(1)!) ?? 0;
  final unit = match.group(2) ?? '';
  final double wan;
  if (unit == '亿') {
    wan = number * 10000;
  } else if (unit == '万') {
    wan = number;
  } else {
    // 裸数字按原始计数处理（线上当前形态）。
    wan = number / 10000;
  }
  if (wan <= 0) return '';
  final rounded = wan.round();
  if (rounded <= 0) return '';
  return '${rounded}w+';
}
