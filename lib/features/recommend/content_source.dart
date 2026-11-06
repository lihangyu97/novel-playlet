import '../../data/api/api_client.dart';
import '../../data/models/feed_page.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';
import 'recommend_item.dart';

/// 一个内容分类「如何向上游取推荐流 / 搜索」的策略。
///
/// 只承载"分类 → 上游请求差异"：首页流的 `tab_type`、搜索走哪个 tab、漫剧
/// 没有游标时的搜索兜底。卡片、页面布局、路由都不在这里——它们由页面按
/// [RecommendItem] 的具体类型 `switch` 出来。
///
/// 实现都是无状态常量（[RecommendCategory.source] 直接持有实例），不要在
/// 这里面缓存请求结果：列表状态在 `RecommendFeedController` 里。
abstract interface class ContentSource {
  /// 推荐流的一页。[sessionId] 翻页时必须原样回传（上游否则会换设备）。
  Future<FeedPage<RecommendItem>> feed(
    ApiClient api, {
    int offset = 0,
    String? sessionId,
  });

  /// 搜索的一页。搜索不需要 session，游标只认 `offset`。
  Future<FeedPage<RecommendItem>> search(
    ApiClient api,
    String query, {
    int offset = 0,
  });
}

/// 小说：书籍推荐首页流（`tab_type=2`）+ 书籍搜索 tab（`tab_type=3`）。
final class NovelSource implements ContentSource {
  const NovelSource();

  @override
  Future<FeedPage<RecommendItem>> feed(
    ApiClient api, {
    int offset = 0,
    String? sessionId,
  }) async =>
      _novelPage(await api.recommend(offset: offset, sessionId: sessionId));

  @override
  Future<FeedPage<RecommendItem>> search(
    ApiClient api,
    String query, {
    int offset = 0,
  }) async => _novelPage(await api.search(query, offset: offset));
}

/// 短剧：看剧首页流（`tab_type=8`）+ 短剧搜索 tab（`tab_type=11`）。
final class DramaSource implements ContentSource {
  const DramaSource();

  static const _feedTabType = 8;
  static const _searchTabType = 11;

  @override
  Future<FeedPage<RecommendItem>> feed(
    ApiClient api, {
    int offset = 0,
    String? sessionId,
  }) async => _videoPage(
    await api.videoFeed(
      tabType: _feedTabType,
      offset: offset,
      sessionId: sessionId,
    ),
  );

  @override
  Future<FeedPage<RecommendItem>> search(
    ApiClient api,
    String query, {
    int offset = 0,
  }) async => _videoPage(
    await api.searchVideos(query, tabType: _searchTabType, offset: offset),
  );
}

/// 漫剧：上游没有独立的漫剧搜索 tab，也没有漫剧首页流游标。
///
/// - 首页流 `tab_type=24` 只有一屏、没有游标，所以首屏同时取一页搜索兜底，
///   把兜底的游标当作下一页游标，列表一上来就能继续翻页；
/// - 后续页只能走搜索兜底：借短剧搜索 tab（`tab_type=11`）+ 关键词「漫剧」，
///   再按卡片元数据只要漫剧（`genre=205` / 「漫剧」标签，见
///   `parseManjuSearchPage`）。
final class ManjuSource implements ContentSource {
  const ManjuSource();

  static const _feedTabType = 24;
  static const _searchTabType = 11;

  /// 首页流游标耗尽后，翻页兜底用的搜索关键词。
  static const _fallbackQuery = '漫剧';

  @override
  Future<FeedPage<RecommendItem>> feed(
    ApiClient api, {
    int offset = 0,
    String? sessionId,
  }) async {
    // offset > 0 = 翻页：首页流没有游标，只能继续走搜索兜底。
    if (offset > 0) return _searchPage(api, _fallbackQuery, offset: offset);

    FeedPage<VideoSeries>? feed;
    Object? feedError;
    try {
      feed = await api.videoFeed(tabType: _feedTabType);
    } catch (error) {
      feedError = error;
    }
    FeedPage<VideoSeries>? fallback;
    try {
      fallback = await _manjuSearch(api, _fallbackQuery);
    } catch (_) {
      // 兜底失败只意味着暂时没有更多，不影响已拿到的首页流。
    }
    // 两个请求都失败才报错；只挂一个时先展示拿到的内容，滚动到底部的
    // 「重试」还能继续走兜底。
    if (feed == null && fallback == null) throw feedError!;

    final items = <RecommendItem>[];
    final seen = <String>{};
    for (final series in [...?feed?.items, ...?fallback?.items]) {
      if (!series.isValid || !seen.add(series.id)) continue;
      items.add(VideoRecommendItem(series));
    }
    return FeedPage(items: items, nextOffset: fallback?.nextOffset);
  }

  @override
  Future<FeedPage<RecommendItem>> search(
    ApiClient api,
    String query, {
    int offset = 0,
  }) async => _searchPage(api, query, offset: offset);

  Future<FeedPage<RecommendItem>> _searchPage(
    ApiClient api,
    String query, {
    required int offset,
  }) async => _videoPage(await _manjuSearch(api, query, offset: offset));

  /// 漫剧的搜索 / 翻页兜底：借短剧搜索 tab，只要漫剧卡片。
  Future<FeedPage<VideoSeries>> _manjuSearch(
    ApiClient api,
    String query, {
    int offset = 0,
  }) => api.searchVideos(
    query,
    tabType: _searchTabType,
    offset: offset,
    manjuOnly: true,
  );
}

/// 上游一页 → 推荐流一页。
FeedPage<RecommendItem> _novelPage(FeedPage<NovelItem> page) => FeedPage(
  items: [for (final item in page.items) NovelRecommendItem(item)],
  nextOffset: page.nextOffset,
  sessionId: page.sessionId,
);

FeedPage<RecommendItem> _videoPage(FeedPage<VideoSeries> page) => FeedPage(
  items: [for (final item in page.items) VideoRecommendItem(item)],
  nextOffset: page.nextOffset,
  sessionId: page.sessionId,
);
