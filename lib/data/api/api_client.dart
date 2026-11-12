import 'dart:async';
import 'dart:convert';

import '../../core/backend/backend_transport.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter.dart';
import '../models/chapter_content.dart';
import '../models/chapter_ideas.dart';
import '../models/comment_reply.dart';
import '../models/feed_page.dart';
import '../models/json_utils.dart';
import '../models/novel_item.dart';
import '../models/search_cue.dart';
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

  /// 搜索框轮播热词（cue）。
  ///
  /// 上游一次返回一整组词 + 轮播间隔，由 UI 自己轮播；`tab_type` 是书城 tab
  /// （默认 2 = 小说，见 `search_cue` 内核 handler）。
  Future<SearchCue> searchCue({
    int tabType = 2,
    String tabName = '',
    int cueType = 0,
  }) async {
    final payload = await _getJson('/api/v1/search/cue', {
      'tab_type': '$tabType',
      'cue_type': '$cueType',
      if (tabName.isNotEmpty) 'tab_name': tabName,
    });
    return SearchCue.fromPayload(payload);
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
  /// 默认模式：内核把整集下载进加密缓存后返回 `/src/<id>.mp4`，播放器按普通
  /// HTTP 拉明文分片。`stream: true` 时带 `mode=stream`：内核立即返回同一个
  /// 回环地址并**在后台继续下载**（边下边播），`/src` 的 Range 请求会等待尚未
  /// 下载到的字节，播放页因此不用再等整集落盘。内核已有完整缓存时
  /// stream 直接返回完成文件（`streaming: false`）；`.m4s/.ts` 等不支持流式的
  /// 形态也由内核退回整集下载后返回 URL。
  Future<VideoSource> videoSource(
    String episodeId, {
    bool refresh = false,
    int? maxHeight,
    bool stream = false,
  }) async {
    final payload = await _getJson(
      '/api/v1/videos/${Uri.encodeComponent(episodeId)}',
      // refresh=1：内核删掉本地缓存文件后重新下载。播放失败（半截/坏缓存）
      // 时用它能真正重来，否则重试只会拿回同一份坏文件。
      // mode=stream：边下边播（见方法注释），不传时保持整集下载语义。
      // variants=0：播放页不需要清晰度列表，别让内核为它多拉一次 fallback。
      // max_height：离线/下载清晰度上限（短边 ≤ N 的最高档）。
      {
        if (refresh) 'refresh': '1',
        if (maxHeight != null && maxHeight > 0) 'max_height': '$maxHeight',
        if (stream) 'mode': 'stream',
        'variants': '0',
      },
      // 首次播放要等整集下载 + 写密钥 sidecar，默认 20s 不够。
      timeout: const Duration(seconds: 120),
    );
    final source = VideoSource.fromPayload(payload);
    final url = absoluteUrl(source.url);
    if (url.isEmpty) {
      throw ApiException('上游没有返回可播放地址（video_url 为空）');
    }
    // 下载失败时内核会退回「远程地址 + key」的流式形态；那种地址是密文，
    // 播放器不能直接播，这里明确失败而不是让 AVPlayer 黑屏。
    if (source.keyHex.isNotEmpty && !url.contains('/src/')) {
      throw ApiException(
        '整集缓存失败：内核只拿到了远程加密流（${Uri.tryParse(url)?.host ?? 'CDN'}），'
        '播放器无法直接播放。',
      );
    }
    return VideoSource(
      url: url,
      keyHex: source.keyHex,
      variants: source.variants,
      appliedVariant: source.appliedVariant,
      qualityFallback: source.qualityFallback,
      streaming: source.streaming,
    );
  }

  /// 只查内核本地 `/src` 缓存（`mode=cached`），**不请求上游**。
  ///
  /// 命中返回可播放的绝对地址；未命中/内核不可用返回 null，调用方回退到
  /// [videoSource] 正常取流。切集先探它，自动缓存命中的集就不用再付一次
  /// 上游往返；断网时也能播。
  Future<String?> cachedVideoUrl(String episodeId) async {
    if (episodeId.isEmpty) return null;
    final payload = await _getJson(
      '/api/v1/videos/${Uri.encodeComponent(episodeId)}',
      const {'mode': 'cached'},
      // 只 stat 本地文件，正常是毫秒级；超时按 miss 处理。
      timeout: const Duration(seconds: 5),
    );
    final data = unwrapEnvelope(payload);
    if (data['cached'] != true) return null;
    final url = absoluteUrl(firstString(data, ['video_url']));
    return url.isEmpty ? null : url;
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

  /// 取一章正文，优先图文接口；只有"这条链路本身取不到"的失败才回退纯文本接口。
  ///
  /// 回退只针对非瞬时语义失败（解析失败/正文为空/badInput 等）：超时、限流、
  /// 上游 5xx、设备注册失效与取消（[TimeoutException]）直接原样抛出，不再发
  /// 第二个请求——那类失败换接口不会变好，只会把用户等待翻倍、把上游错误
  /// 放大一次（P1-7）。
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
      if (!_shouldFallbackToPlainChapter(error)) rethrow;
      firstError = error;
    }
    try {
      final payload = await _getJson('/api/v1/chapters/$encoded', const {});
      return parseChapterContent(payload, chapterId: itemId, title: title);
    } catch (fallbackError) {
      // 取消不是错误：保持 TimeoutException 语义，交给上层静默处理。
      if (fallbackError is TimeoutException) rethrow;
      // 最终异常取第二次（纯文本接口）的 message + kind：它是最终决定结果的
      // 那条失败，语义一致，不与第一次的 kind 混用。
      if (fallbackError is ApiException) rethrow;
      throw ApiException(
        firstError is ApiException
            ? '无法获取正文：${firstError.message}'
            : '无法获取正文（响应解析失败）',
      );
    }
  }

  /// 图文接口失败是否值得回退纯文本接口。
  ///
  /// 瞬时失败（超时/限流/上游 5xx）由 Rust 侧按策略重试，Dart 不再放大；
  /// 设备注册失效要重启应用；499 取消是 [TimeoutException]。这些都不能回退。
  bool _shouldFallbackToPlainChapter(Object error) {
    if (error is TimeoutException) return false;
    if (error is BackendTimeoutException) return false;
    if (error is ApiException) {
      return !error.kind.isTransient && !error.kind.needsRestart;
    }
    // 本地解析/格式异常等意外：另一条接口可能拿到可解析的正文。
    return true;
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

  /// 一章的段评/章末评论汇总（计数 + 评论 id，整章一次、不分页）。
  ///
  /// 段评是阅读页装饰：业务上「没有段评」也会返回不可用 code，这里按空处理，
  /// 由调用方决定隐藏入口；真正的网络/鉴权失败仍抛 [ApiException]。
  Future<ChapterIdeas> chapterIdeas(
    String itemId, {
    String itemVersion = '',
    int commentSource = 3,
  }) async {
    if (itemId.isEmpty) return ChapterIdeas.empty;
    final payload = await _getJson(
      '/api/v1/chapters/${Uri.encodeComponent(itemId)}/reviews',
      {
        'comment_source': '$commentSource',
        if (itemVersion.isNotEmpty) 'item_version': itemVersion,
      },
      timeout: const Duration(seconds: 15),
    );
    return ChapterIdeas.fromPayload(payload);
  }

  /// 某一段（或章末聚合桶）的段评正文，`cursor` 翻页。
  ///
  /// [itemVersion] 来自目录；缺了上游会回 103001，所以调用方要尽量带上。
  /// [paraIndex] 用章末桶时传 [ChapterIdeas.chapterEndParaIndex]。
  Future<BookCommentPage> paragraphComments(
    String bookId,
    String itemId, {
    required int paraIndex,
    required String itemVersion,
    int count = 20,
    String cursor = '',
  }) async {
    final payload = await _getJson(
      '/api/v1/books/${Uri.encodeComponent(bookId)}/reviews',
      {
        'book_id': bookId,
        'group_id': itemId,
        'group_type': '15',
        'comment_source': '2',
        'comment_type': '1',
        'server_channel': '38',
        'para_index': '$paraIndex',
        if (itemVersion.isNotEmpty) 'item_version': itemVersion,
        'count': '$count',
        if (cursor.isNotEmpty) 'cursor': cursor,
      },
      timeout: const Duration(seconds: 20),
    );
    return BookCommentPage.fromCommentListPayload(payload);
  }

  /// 书评列表（旧接口，带 `comment_cnt` / `score_cnt` / `2.6万人点评` 文案）。
  ///
  /// 用 `offset` 翻页，`nextOffset` 由响应给出。
  Future<BookCommentPage> bookComments(
    String bookId, {
    int count = 10,
    int offset = 0,
  }) async {
    final payload = await _getJson(
      '/api/v1/books/${Uri.encodeComponent(bookId)}/comments',
      {'count': '$count', 'offset': '$offset'},
      timeout: const Duration(seconds: 20),
    );
    return BookCommentPage.fromLegacyPayload(payload);
  }

  /// 一条评论的回复列表（段评 / 书评共用；短剧回复是另一条路由）。
  Future<CommentReplyPage> commentReplies(
    String commentId, {
    required String bookId,
    required String groupId,
    int count = 10,
  }) async {
    if (commentId.isEmpty) return CommentReplyPage.empty;
    final payload = await _getJson(
      '/api/v1/comments/${Uri.encodeComponent(commentId)}/replies',
      {
        'comment_id': commentId,
        'book_id': bookId,
        'group_id': groupId,
        'count': '$count',
      },
      timeout: const Duration(seconds: 20),
    );
    return CommentReplyPage.fromPayload(payload);
  }

  /// 短剧整体剧评（「详情页」评论区），`cursor` 翻页。
  ///
  /// 与小说书评不是同一条上游：短剧剧评复用 `comment/list`，
  /// `comment_source=1`、`group_type=1`（Book），`group_id` 就是剧集 id。
  /// 返回形状与段评/书评一致（`data_list` + `common_list_info`）。
  Future<BookCommentPage> seriesComments(
    String seriesId, {
    int count = 10,
    String cursor = '',
    int sort = 1,
  }) async {
    if (seriesId.isEmpty) return BookCommentPage.empty;
    final payload = await _getJson(
      '/api/v1/series/${Uri.encodeComponent(seriesId)}/comments',
      {
        'count': '$count',
        'sort': '$sort',
        if (cursor.isNotEmpty) 'cursor': cursor,
      },
      timeout: const Duration(seconds: 20),
    );
    return BookCommentPage.fromCommentListPayload(payload);
  }

  /// 某一集的评论（官方「右栏热评」：按 vid 取，`total` 就是该集评论数）。
  ///
  /// 上游还是同一条 `comment/list`，但 `group_id` 换成 vid、`group_type=30`
  /// （SeriesVideo）、`comment_source=4` / `comment_type=4`；一次最多 20 条，
  /// 没有 cursor，所以只当「本集评论」首屏用，不做翻页。
  ///
  /// [vid] 为空时接口会静默退回剧集 id（变成整部剧的评论），调用方必须先
  /// 判断 vid 非空，否则「每集评论」会悄悄串成剧级评论。
  Future<BookCommentPage> episodeComments(
    String seriesId,
    String vid, {
    int serverChannel = 17,
  }) async {
    if (seriesId.isEmpty || vid.isEmpty) return BookCommentPage.empty;
    final payload = await _getJson(
      '/api/v1/series/${Uri.encodeComponent(seriesId)}/hot-comments',
      {'vid': vid, 'server_channel': '$serverChannel'},
      timeout: const Duration(seconds: 20),
    );
    return BookCommentPage.fromCommentListPayload(payload);
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
