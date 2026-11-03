import 'dart:convert';

import '../../core/backend/backend_transport.dart';
import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/chapter_content.dart';
import '../models/json_utils.dart';
import '../models/novel_item.dart';

/// 业务接口层：路径 + 查询参数 + 解析。
///
/// 这里刻意不做缓存、不做重试、不碰 UI——签名/设备池/限流在 Rust 核里，
/// 页面状态在 controller 里，这一层只负责"一次请求 → 一个模型"。
class ApiClient {
  ApiClient(this._transport);

  final BackendTransport _transport;

  /// 上游书城小说推荐（`tab_type=2`）。[sessionId] 翻页时必须回传，否则
  /// 上游会换设备导致 101116。
  Future<NovelFeedPage> recommend({
    int offset = 0,
    String? sessionId,
  }) async {
    final query = <String, String>{
      'tab_type': '2',
      'offset': '$offset',
      'tab_index': '0',
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
    };
    final payload = await _getJson('/api/v1/recommend/homepage', query);
    final data = unwrapEnvelope(payload);
    return NovelFeedPage(
      items: parseNovelItems(payload),
      nextOffset: asInt(data['next_offset'], 0) > 0
          ? asInt(data['next_offset'])
          : null,
      sessionId: firstString(data, ['session_id']),
    );
  }

  /// 书籍搜索（`tab_type=3` = 上游"书籍"tab）。
  Future<NovelFeedPage> search(String query, {int offset = 0}) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      'tab_type': '3',
      'offset': '$offset',
      'count': '10',
    });
    final items = parseSearchNovels(payload);
    final nextOffset = _searchNextOffset(payload, offset: offset);
    return NovelFeedPage(items: items, nextOffset: nextOffset);
  }

  Future<BookDetail> bookDetail(String bookId) async {
    final payload = await _getJson(
      '/api/v1/books/${Uri.encodeComponent(bookId)}/detail',
      const {},
    );
    return BookDetail.fromPayload(payload);
  }

  Future<List<Chapter>> directory(String bookId) async {
    final payload = await _getJson(
      '/api/v1/books/${Uri.encodeComponent(bookId)}/directory',
      const {},
    );
    return parseDirectory(payload);
  }

  /// 取一章正文，优先图文接口，失败回退纯文字接口。
  Future<ChapterContent> chapter(String itemId, {String title = ''}) async {
    final encoded = Uri.encodeComponent(itemId);
    Object? firstError;
    try {
      final payload = await _getJson('/api/v1/chapters/$encoded/novel', const {});
      return parseChapterContent(payload, chapterId: itemId, title: title);
    } catch (error) {
      firstError = error;
    }
    try {
      final payload = await _getJson('/api/v1/chapters/$encoded', const {});
      return parseChapterContent(payload, chapterId: itemId, title: title);
    } catch (error) {
      throw ApiException(
        '无法获取正文：${firstError is ApiException ? firstError.message : error}',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, String> query,
  ) async {
    final encodedQuery = Uri(queryParameters: query).query;
    final response = await _transport.send(
      'GET',
      path,
      query: encodedQuery.isEmpty ? null : encodedQuery,
    );
    if (response.statusCode != 200) {
      // 内核把错误也包成 JSON，能读 message 就透出去。
      String message = '请求失败（HTTP ${response.statusCode}）';
      try {
        final payload = jsonDecode(response.text);
        if (payload is Map) {
          final detail = firstString(
            Map<String, dynamic>.from(payload),
            ['error', 'message', 'msg'],
          );
          if (detail.isNotEmpty) message = detail;
        }
      } catch (_) {
        // 非 JSON 响应保持状态码文案。
      }
      throw ApiException(message);
    }
    final decoded = jsonDecode(response.text);
    if (decoded is! Map) {
      throw ApiException('响应格式异常');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

const _novelIdKeys = ['book_id', 'item_id', 'id', 'cell_id'];
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

/// 从推荐/搜索载荷里递归捞出小说卡片。
///
/// 上游把卡片藏在 `cell_data` / `book_data`（单对象或数组）/ 卡片直挂三种
/// 位置，深度不定，所以按 key 白名单递归；短剧/漫画/听书卡片带自己的 id
/// 字段而**没有** `book_id`，据此排除。
List<NovelItem> parseNovelItems(Map<String, dynamic> payload) {
  final root = asMap(payload['data']) ?? payload;
  final out = <NovelItem>[];
  final seen = <String>{};

  void add(Map<String, dynamic> raw) {
    final item = NovelItem.fromRaw(raw);
    if (!item.isValid) return;
    if (seen.add(item.id)) out.add(item);
  }

  void visit(Object? value, int depth) {
    if (depth > 12 || value == null) return;
    if (value is List) {
      for (final child in value) {
        visit(child, depth + 1);
      }
      return;
    }
    final map = asMap(value);
    if (map == null) return;

    final hasNovelId = _novelIdKeys.any((key) => asString(map[key]).isNotEmpty);
    final hasOtherId = _nonNovelKeys.any(
      (key) => asString(map[key]).isNotEmpty,
    );
    if (hasNovelId && !(hasOtherId && asString(map['book_id']).isEmpty)) {
      add(map);
    }

    for (final key in const [
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
    ]) {
      if (map.containsKey(key)) visit(map[key], depth + 1);
    }
  }

  visit(root, 0);
  return out;
}

/// 搜索响应：只取"书籍"tab（`tab_type=3`），兼容综合 tab（1）。
List<NovelItem> parseSearchNovels(Map<String, dynamic> payload) {
  final data = asMap(payload['data']) ?? payload;
  final tabs = asList(data['search_tabs']).map(asMap).whereType<Map<String, dynamic>>();
  final selected = <Map<String, dynamic>>[];
  for (final tab in tabs) {
    final type = asInt(tab['tab_type']);
    if (type == 3 || type == 1) selected.add(tab);
  }
  final source = selected.isEmpty ? tabs.toList() : selected;
  final items = <NovelItem>[];
  final seen = <String>{};
  for (final tab in source) {
    for (final item in parseNovelItems({'data': {'search_tabs': [tab]}})) {
      if (seen.add(item.id)) items.add(item);
    }
  }
  return items;
}

int? _searchNextOffset(Map<String, dynamic> payload, {required int offset}) {
  final data = asMap(payload['data']) ?? payload;
  for (final tab in asList(data['search_tabs']).map(asMap).whereType<Map<String, dynamic>>()) {
    final type = asInt(tab['tab_type']);
    if (type != 3 && type != 1) continue;
    final next = asInt(tab['next_offset']);
    if (next > offset) return next;
  }
  return null;
}
