import '../models/json_utils.dart';

/// 卡片解析链路的适配口。
///
/// [walkCards] 负责两条链路完全相同的三件事：按 key 白名单递归下钻、深度
/// 上限、按 id 去重；adapter 只负责"这一层 map 是不是本类型卡片 / 字段怎么
/// 取"。刻意只服务小说和短剧两条链路，不做通用反射或字段 DSL。
abstract class CardAdapter<T> {
  const CardAdapter();

  /// 递归深度上限。两条链路历史取值不同（小说 12 / 短剧 14），保持原样。
  int get depthLimit;

  /// 继续向下递归的 key 白名单，顺序即遍历顺序（卡片先后的顺序依赖它）。
  List<String> get childKeys;

  /// 同一个 map 可能派生多张卡片，默认 map 自己就是一张候选卡。
  ///
  /// 短剧模板卡要把 `video_data[].video_detail` 合并回外层卡片再取值，
  /// 所以会覆盖成"先给合并卡，再给 map 自己"。
  Iterable<Map<String, dynamic>> candidates(Map<String, dynamic> raw) => [raw];

  /// 把候选 map 解析成本类型卡片；不是本类型或字段不足时返回 null。
  T? parse(Map<String, dynamic> raw);

  /// 去重键：同一张卡片可能出现在多个推荐区块里。
  String idOf(T card);
}

/// 从推荐/搜索载荷里递归捞出卡片。
///
/// 根节点优先取 `payload.data`（兼容 `{code, data}` 信封），按
/// [CardAdapter.childKeys] 深度优先遍历，[CardAdapter.idOf] 去重并保持
/// 首次出现的顺序。
List<T> walkCards<T>(Map<String, dynamic> payload, CardAdapter<T> adapter) {
  final root = asMap(payload['data']) ?? payload;
  final out = <T>[];
  final seen = <String>{};

  void visit(Object? value, int depth) {
    if (depth > adapter.depthLimit || value == null) return;
    if (value is List) {
      for (final child in value) {
        visit(child, depth + 1);
      }
      return;
    }
    final map = asMap(value);
    if (map == null) return;

    for (final candidate in adapter.candidates(map)) {
      final card = adapter.parse(candidate);
      if (card == null) continue;
      if (seen.add(adapter.idOf(card))) out.add(card);
    }

    for (final key in adapter.childKeys) {
      if (map.containsKey(key)) visit(map[key], depth + 1);
    }
  }

  visit(root, 0);
  return out;
}
