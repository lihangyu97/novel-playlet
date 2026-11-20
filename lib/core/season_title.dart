/// 短剧标题里的「第几季」。
///
/// 上游没有季字段：每季是一个独立的 `series_id`，`recommend_group_id` 就是
/// 自己的剧 id，详情响应也只有 `series_sub_title_list`（集数/热度），没有
/// 「同一系列其他季」。季只写在标题文字里，而且形态并不统一：
///
/// - `反差大佬：我家小师妹超正经第七季`
/// - `全能鬼才小师妹（第一季）`
/// - `大佬，你该出手了第五季：我真不是大佬啊`
///
/// 卡片标题固定两行，100pt 卡宽下两行只放得下 12–13 个字，尾部的季正好被
/// 省略号吃掉（`反差大佬：我家小师妹超正经第七季` 共 16 字）。所以把季单独
/// 拎到封面角标上，标题文字保持原样不动。
library;

/// 「第 3 季 / 第三季」，允许「第」和季号之间有空格，季号最多三位中文数字
/// （九十九）。
final _seasonPattern = RegExp(r'第\s*([0-9]+|[零一二两三四五六七八九十]{1,3})\s*季');

const _digitValues = <String, int>{
  '零': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

/// 标题里的季号；没有「第 N 季」或季号解析不出时返回 null。
///
/// 在标题**任意位置**匹配而不是只看末尾：真实标题里有 `（第一季）` 这种
/// 括号包裹的，也有 `第五季：副标题` 这种季后面还有内容的。标题里出现
/// 「四季」「季度」这类没有「第」的字样不会误伤。
int? seasonOf(String title) {
  for (final match in _seasonPattern.allMatches(title)) {
    final season = _parseSeasonNumber(match.group(1)!);
    if (season != null && season >= 1 && season <= 99) return season;
  }
  return null;
}

/// 阿拉伯数字直接取值；中文数字按「十」拆成十位/个位（十 = 10、十一 = 11、
/// 二十 = 20、二十三 = 23）。其余形态（如「二三」）不是合法季号，返回 null。
int? _parseSeasonNumber(String raw) {
  final arabic = int.tryParse(raw);
  if (arabic != null) return arabic;

  if (raw.contains('十')) {
    final parts = raw.split('十');
    if (parts.length != 2) return null;
    final tens = parts[0].isEmpty ? 1 : _digitValues[parts[0]];
    final ones = parts[1].isEmpty ? 0 : _digitValues[parts[1]];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }

  if (raw.length != 1) return null;
  return _digitValues[raw];
}
