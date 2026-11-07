import 'dart:convert';

import '../../core/backend/backend_transport.dart';
import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/chapter_content.dart';
import '../models/feed_page.dart';
import '../models/json_utils.dart';
import '../models/novel_item.dart';
import '../models/video_detail.dart';
import '../models/video_series.dart';
import '../models/video_source.dart';
import '../parsers/novel_parsers.dart';
import '../parsers/video_parsers.dart';

/// 业务接口层：路径 + 查询参数 + 解析。
///
/// 这里刻意不做缓存、不做重试、不碰 UI——签名/设备池/限流在 Rust 核里，
/// 页面状态在 controller 里，这一层只负责"一次请求 → 一个模型"。
class ApiClient {
  ApiClient(this._transport);

  final BackendTransport _transport;

  /// 上游书城小说推荐（`tab_type=2`）。[sessionId] 翻页时必须回传，否则
  /// 上游会换设备导致 101116。
  Future<FeedPage<NovelItem>> recommend({
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
    return FeedPage<NovelItem>(
      items: parseNovelItems(payload),
      nextOffset: nextOffset > offset ? nextOffset : null,
      sessionId: tab == null ? null : firstString(tab, ['session_id']),
    );
  }

  /// 书籍搜索（`tab_type=3` = 上游"书籍"tab）。
  Future<FeedPage<NovelItem>> search(String query, {int offset = 0}) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      // 上游 tab 语义：1 综合 / 2 听书 / 3 书籍 / 8 漫画 / 11 短剧。
      'tab_type': '3',
      'offset': '$offset',
      'count': '10',
    });
    final items = parseSearchNovels(payload);
    final nextOffset = _searchNextOffset(payload, offset: offset);
    return FeedPage<NovelItem>(items: items, nextOffset: nextOffset);
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
  Future<FeedPage<VideoSeries>> videoFeed({
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
    return FeedPage<VideoSeries>(
      items: parseVideoSeries(data),
      nextOffset: nextOffset > offset ? nextOffset : null,
      sessionId: firstString(tab, ['session_id']),
    );
  }

  /// 视频类搜索（`/api/v1/search`，纯端点）。
  ///
  /// [tabType] 取上游搜索 tab：11 = 短剧、8 = 漫画。搜索响应里可能同时有多个
  /// `search_tabs`，只解析匹配的那个；没有匹配 tab 时返回空列表（页面显示空
  /// 结果），避免把别的分类当成本分类画。
  ///
  /// [manjuOnly] 是上游缺口的解析口径（不是分类逻辑）：上游没有「漫剧」搜索
  /// tab，漫剧卡片混在短剧 tab 里，只能按卡片元数据（`genre=205` /「漫剧」
  /// 标签）过滤，游标也不时缺失（见 [parseManjuSearchPage]）。
  Future<FeedPage<VideoSeries>> searchVideos(
    String query, {
    int tabType = 11,
    int offset = 0,
    bool manjuOnly = false,
  }) async {
    final payload = await _getJson('/api/v1/search', {
      'query': query,
      'tab_type': '$tabType',
      'offset': '$offset',
      'count': '10',
    });
    if (manjuOnly) return parseManjuSearchPage(payload, offset: offset);
    return FeedPage<VideoSeries>(
      items: parseSearchVideoSeries(payload, tabType: tabType),
      nextOffset: _searchNextOffset(
        payload,
        offset: offset,
        tabTypes: {tabType},
      ),
    );
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
  Future<VideoSource> videoSource(
    String episodeId, {
    bool refresh = false,
  }) async {
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
      final payload = await _getJson(
        '/api/v1/chapters/$encoded/novel',
        const {},
      );
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
        // 透传底层语义（超时/限流等），上层需要时能按 kind 分支。
        kind: firstError is ApiException
            ? firstError.kind
            : ApiErrorKind.unknown,
      );
    }
  }

  /// 批量取正文（内核 `/api/v1/chapters/batch`，约 20 章/批）。
  ///
  /// 返回 `itemId → 正文`；整包失败/未解密/空正文的章不会出现在结果里，
  /// 调用方逐章回退 [chapter]（离线下载器就是这样做的）。
  Future<Map<String, ChapterContent>> chaptersBatch(
    List<Chapter> chapters, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final ids = [
      for (final chapter in chapters)
        if (chapter.id.isNotEmpty) chapter.id,
    ];
    if (ids.isEmpty) return const <String, ChapterContent>{};
    final payload = await _getJson('/api/v1/chapters/batch', {
      'item_ids': ids.join(','),
    }, timeout: timeout);
    return parseBatchChapterContents(payload);
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, String> query, {
    Duration? timeout,
  }) async {
    final encodedQuery = Uri(queryParameters: query).query;
    final BackendResponse response;
    try {
      response = await _transport.send(
        'GET',
        path,
        query: encodedQuery.isEmpty ? null : encodedQuery,
        timeout: timeout ?? BackendTransport.defaultTimeout,
      );
    } on BackendTimeoutException {
      // B2：内核 504 是真实超时，在这里归一成带 kind 的 ApiException；499
      // 取消仍是 TimeoutException，不在这里接（取消不是用户可见错误）。
      throw ApiException(
        ApiErrorKind.timeout.userCopy,
        kind: ApiErrorKind.timeout,
      );
    }
    if (response.statusCode != 200) {
      // 内核把错误也包成 JSON，能读 message 就透出去；kind 一并透出，
      // 供上层按语义分支（本层不重试）。读不到就保持 unknown。
      // 504 即使没有 JSON body 也按超时处理（部分传输实现会原样返回状态码）。
      var kind = response.statusCode == 504
          ? ApiErrorKind.timeout
          : ApiErrorKind.unknown;
      String message = '请求失败（HTTP ${response.statusCode}）';
      try {
        final payload = jsonDecode(response.text);
        if (payload is Map) {
          final map = Map<String, dynamic>.from(payload);
          final wireKind = ApiErrorKind.fromWire(map['kind']);
          if (wireKind != ApiErrorKind.unknown) kind = wireKind;
          final detail = firstString(map, ['error', 'message', 'msg']);
          if (detail.isNotEmpty) message = detail;
        }
      } catch (_) {
        // 非 JSON 响应保持状态码文案与 kind 的默认判断。
      }
      // 技术兜底 message（如 "HTTP 500"）换成 kind 短句；具体 message 原样抛出。
      final exception = ApiException(message, kind: kind);
      throw ApiException(
        apiErrorCopy(exception, fallback: message),
        kind: kind,
      );
    }
    final decoded = jsonDecode(response.text);
    if (decoded is! Map) {
      // HTTP 200 但不是信封：格式异常，语义未知。
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

int? _searchNextOffset(
  Map<String, dynamic> payload, {
  required int offset,
  Set<int> tabTypes = const {1, 3},
}) {
  final data = asMap(payload['data']) ?? payload;
  for (final tab in asList(
    data['search_tabs'],
  ).map(asMap).whereType<Map<String, dynamic>>()) {
    final type = asInt(tab['tab_type']);
    if (!tabTypes.contains(type)) continue;
    final next = asInt(tab['next_offset']);
    if (next > offset) return next;
  }
  return null;
}
