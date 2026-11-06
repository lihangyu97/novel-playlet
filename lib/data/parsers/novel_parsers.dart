import '../models/json_utils.dart';
import '../models/novel_item.dart';
import 'card_walker.dart';

// cell_id 属于"区块"，不属于书：排行榜区块本身也带 cell_id，
// 用它会把「排行榜」当成一本书。只认书自己的身份字段。
const _novelIdKeys = ['book_id', 'item_id', 'id'];
const _nonNovelKeys = [
  'video_id',
  'vid',
  'series_id',
  'pseries_id',
  'manga_id',
  'comic_id',
  'audio_book_id',
  'audio_id',
];

/// 小说链路的下钻 key 白名单（顺序即遍历顺序）。
const _novelChildKeys = [
  'tab_item',
  'cell_data',
  'cell_view',
  'search_tabs',
  'book_data',
  'items',
  'lists',
  'item_data_list',
  'recommend_list',
  'data',
];

/// 小说卡片的适配口。
///
/// 短剧/漫画/听书卡片带自己的 id 字段而**没有** `book_id`，据此排除；
/// 字段提取全部交给 [NovelItem.fromRaw]（保留原有的内层回退规则）。
class NovelCardAdapter extends CardAdapter<NovelItem> {
  const NovelCardAdapter();

  @override
  int get depthLimit => 12;

  @override
  List<String> get childKeys => _novelChildKeys;

  @override
  NovelItem? parse(Map<String, dynamic> raw) {
    final hasNovelId = _novelIdKeys.any((key) => asString(raw[key]).isNotEmpty);
    final hasOtherId = _nonNovelKeys.any(
      (key) => asString(raw[key]).isNotEmpty,
    );
    // 短剧卡也可能带 book_id（混排区块），这时仍按小说认领。
    if (!hasNovelId || (hasOtherId && asString(raw['book_id']).isEmpty)) {
      return null;
    }
    final item = NovelItem.fromRaw(raw);
    return item.isValid ? item : null;
  }

  @override
  String idOf(NovelItem card) => card.id;
}

/// 从推荐/搜索载荷里递归捞出小说卡片。
///
/// 上游把卡片藏在 `cell_data` / `book_data`（单对象或数组）/ 卡片直挂三种
/// 位置，深度不定，所以按 key 白名单递归。
List<NovelItem> parseNovelItems(Map<String, dynamic> payload) =>
    walkCards(payload, const NovelCardAdapter());

/// 搜索响应：只取"书籍"tab（`tab_type=3`），兼容综合 tab（1）。
List<NovelItem> parseSearchNovels(Map<String, dynamic> payload) {
  final data = asMap(payload['data']) ?? payload;
  final tabs = asList(data['search_tabs'])
      .map(asMap)
      .whereType<Map<String, dynamic>>();
  final selected = <Map<String, dynamic>>[];
  for (final tab in tabs) {
    final type = asInt(tab['tab_type']);
    if (type == 3 || type == 1) selected.add(tab);
  }
  final source = selected.isEmpty ? tabs.toList() : selected;
  final items = <NovelItem>[];
  final seen = <String>{};
  for (final tab in source) {
    for (final item in parseNovelItems({
      'data': {
        'search_tabs': [tab],
      },
    })) {
      if (seen.add(item.id)) items.add(item);
    }
  }
  return items;
}
