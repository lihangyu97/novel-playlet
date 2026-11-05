import 'dart:convert';

import '../../core/backend/backend_transport.dart';
import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/chapter_content.dart';
import '../models/json_utils.dart';
import '../models/novel_item.dart';
import '../models/video_detail.dart';
import '../models/video_series.dart';
import '../models/video_source.dart';

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
    // 游标与 session 挂在"被回答的那个 tab_item"上（data.tab_item[]），
    // tab 的身份由 data.tab_index 指定；data 顶层没有这两个字段。
    final tab = _answeredRecommendTab(data);
    final nextOffset = tab == null ? 0 : asInt(tab['next_offset']);
    // 上游的 has_more 不可信：实测 has_more=false 时继续用 offset=2 仍会返回
    // 一大批新书。所以只认"游标是否前进"，游标后退/不动才停止翻页。
    return NovelFeedPage(
      items: parseNovelItems(payload),
      nextOffset: nextOffset > offset ? nextOffset : null,
      sessionId: tab == null ? null : firstString(tab, ['session_id']),
    );
  }

  /// 书籍搜索（`tab_type=3` = 上游"书籍"tab）。
  Future<NovelFeedPage> search(String query, {int offset = 0}) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      // 上游 tab 语义：1 综合 / 2 听书 / 3 书籍 / 8 漫画 / 11 短剧。
      'tab_type': '3',
      'offset': '$offset',
      'count': '10',
    });
    final items = parseSearchNovels(payload);
    final nextOffset = _searchNextOffset(payload, offset: offset);
    return NovelFeedPage(items: items, nextOffset: nextOffset);
  }

  /// 视频类分类（短剧 / 漫剧）的推荐流。
  ///
  /// 同一套书城首页接口按 `tab_type` 分类，取值见官方 `BookstoreTabType`
  /// （fqapp 抄的那份在 `lib/models/channel_tab.dart`）：2 推荐/小说、5 听书、
  /// **8 短剧（看剧）**、9 漫画、16 视频 feed、24 漫剧、25 小说、103 短篇。
  /// 之前用 16 是「视频 feed」，上游只回 2 张卡且没有游标；8 才是短剧流，
  /// 实测 6 张/页、`next_offset` 逐页 +1（0→1→2 每页都是新剧），session 稳定。
  /// 漫剧（24）实测 12 张卡但没有游标，只能刷首页。
  ///
  /// 与书城推荐同一套信封：游标与 session 挂在被回答的 `tab_item` 上，翻页
  /// 必须回传 session，否则上游会换设备。
  Future<VideoFeedPage> videoFeed({
    int tabType = 8,
    int offset = 0,
    String? sessionId,
  }) async {
    final payload = await _getJson('/api/v1/recommend/homepage', {
      'tab_type': '$tabType',
      'offset': '$offset',
      'tab_index': '0',
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
    });
    final data = unwrapEnvelope(payload);
    final tab = _answeredRecommendTab(data);
    // 上游会答非所问：`tab_item` 里只有被回答那项带 cell_data，按 `tab_type`
    // 认领。类型对不上就是别的分类的流（fqapp 同样会整页拒绝），不能当本分类画。
    if (tab == null || asInt(tab['tab_type'], -1) != tabType) {
      throw ApiException('推荐数据异常，下拉刷新试试');
    }
    final nextOffset = asInt(tab['next_offset']);
    return VideoFeedPage(
      items: parseVideoSeries(data),
      nextOffset: nextOffset > offset ? nextOffset : null,
      sessionId: firstString(tab, ['session_id']),
    );
  }

  /// 视频类分类的搜索。
  ///
  /// [tabType] 取上游搜索 tab：11 = 短剧；上游没有「漫剧」搜索 tab，暂用 8
  /// （漫画）。搜索响应里可能同时有多个 `search_tabs`，只解析匹配的那个，
  /// 没有匹配 tab 时返回空列表（页面显示空结果），避免把别的分类当成本分类。
  Future<VideoFeedPage> searchVideos(
    String query, {
    int tabType = 11,
    int offset = 0,
  }) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      'tab_type': '$tabType',
      'offset': '$offset',
      'count': '10',
    });
    return VideoFeedPage(
      items: parseSearchVideoSeries(payload, tabType: tabType),
      nextOffset: _searchNextOffset(payload, offset: offset, tabTypes: {tabType}),
    );
  }

  /// 漫剧的搜索 / 翻页兜底。
  ///
  /// 漫剧首页流（`tab_type=24`）只有一屏、没有游标，后续页只能走搜索：
  /// 上游把漫剧混在短剧搜索 tab（`tab_type=11`）里，卡片靠 `genre=205` /
  /// 「漫剧」标签区分（见 [parseManjuSearchPage]）。[query] 传分类名「漫剧」
  /// 就是翻页兜底，传用户输入就是搜索。
  Future<VideoFeedPage> manjuSearch(String query, {int offset = 0}) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      'tab_type': '11',
      'offset': '$offset',
      'count': '10',
    });
    final page = parseManjuSearchPage(payload, offset: offset);
    return VideoFeedPage(items: page.items, nextOffset: page.nextOffset);
  }

  /// 短剧详情（`/api/v1/series/{id}`）。
  Future<VideoDetail> videoDetail(String seriesId) async {
    final payload = await _getJson(
      '/api/v1/series/${Uri.encodeComponent(seriesId)}',
      const {},
    );
    return VideoDetail.fromPayload(payload);
  }

  /// 短剧选集：与小说目录同一条路由，上游按剧集 id 返回分集列表。
  Future<List<Chapter>> videoEpisodes(String seriesId) => directory(seriesId);

  /// 一集的可播放地址。
  ///
  /// 当前走默认（非 stream）模式：内核把整集下载进加密缓存后返回
  /// `/src/<id>.mp4`，播放器只需按普通 HTTP 拉明文分片。流式回环（边下边播）
  /// 见 docs/video-playback.md 的 M1，接入后这里换成 `mode=stream`。
  Future<VideoSource> videoSource(String episodeId, {bool refresh = false}) async {
    final payload = await _getJson(
      '/api/v1/videos/${Uri.encodeComponent(episodeId)}',
      // refresh=1：内核删掉本地缓存文件后重新下载。播放失败（半截/坏缓存）
      // 时用它能真正重来，否则重试只会拿回同一份坏文件。
      {if (refresh) 'refresh': '1'},
      // 首次播放要等整集下载 + 写密钥 sidecar，默认 20s 不够。
      timeout: const Duration(seconds: 120),
    );
    final source = VideoSource.fromPayload(payload);
    final url = absoluteUrl(source.url);
    if (url.isEmpty) {
      throw ApiException('上游没有返回可播放地址（video_url 为空）');
    }
    // 下载失败时内核会退回「远程地址 + key」的流式形态；那种地址是密文，
    // 播放器不能直接播（流式回环见 M1），这里明确失败而不是让 AVPlayer 黑屏。
    if (source.keyHex.isNotEmpty && !url.contains('/src/')) {
      throw ApiException(
        '整集缓存失败：内核只拿到了远程加密流（${Uri.tryParse(url)?.host ?? 'CDN'}），'
        'M1 流式回环未接入。',
      );
    }
    return VideoSource(
      url: url,
      keyHex: source.keyHex,
      variants: source.variants,
    );
  }

  /// 把内核给的相对资源地址（`/src/xxx.mp4`）拼成播放器能直接拉取的绝对地址。
  String absoluteUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme != 'http' && uri.scheme != 'https') return '';
      return uri.host.isEmpty ? '' : raw;
    }
    final base = _transport.baseUrl;
    if (base.isEmpty) return '';
    return Uri.parse(base).resolve(raw).toString();
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
    Map<String, String> query, {
    Duration? timeout,
  }) async {
    final encodedQuery = Uri(queryParameters: query).query;
    final response = await _transport.send(
      'GET',
      path,
      query: encodedQuery.isEmpty ? null : encodedQuery,
      timeout: timeout ?? BackendTransport.defaultTimeout,
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

/// 从推荐响应里挑出"被回答"的 tab：`data.tab_index` 指向 `data.tab_item[]`，
/// 其余 tab 只有标题。取不到时退回第一个带 cell_data 的 tab。
Map<String, dynamic>? _answeredRecommendTab(Map<String, dynamic> data) {
  final tabs = asList(data['tab_item'])
      .map(asMap)
      .whereType<Map<String, dynamic>>()
      .toList();
  if (tabs.isEmpty) return null;
  final index = asInt(data['tab_index'], 0);
  if (index >= 0 && index < tabs.length) return tabs[index];
  for (final tab in tabs) {
    if (asList(tab['cell_data']).isNotEmpty) return tab;
  }
  return tabs.first;
}

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

int? _searchNextOffset(
  Map<String, dynamic> payload, {
  required int offset,
  Set<int> tabTypes = const {1, 3},
}) {
  final data = asMap(payload['data']) ?? payload;
  for (final tab in asList(data['search_tabs']).map(asMap).whereType<Map<String, dynamic>>()) {
    final type = asInt(tab['tab_type']);
    if (!tabTypes.contains(type)) continue;
    final next = asInt(tab['next_offset']);
    if (next > offset) return next;
  }
  return null;
}
