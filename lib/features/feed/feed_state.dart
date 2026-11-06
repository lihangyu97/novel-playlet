import 'package:flutter/foundation.dart';

import '../../data/models/json_utils.dart';

/// 首页流当前展示的是推荐流还是搜索结果。
enum FeedMode { feed, search }

/// 分页列表的通用状态（推荐页各分类共用）。
///
/// 首屏加载/失败由外层 `AsyncValue` 承载；这个类只描述"已有数据、正在追加
/// 下一页"这类页面内状态，所以翻页失败不会清空已展示的列表。
@immutable
class FeedState<T> {
  const FeedState({
    required this.mode,
    required this.query,
    required this.items,
    this.nextOffset,
    this.sessionId,
    this.loadingMore = false,
    this.loadMoreError,
    this.loadMoreRetryable = true,
  });

  /// 推荐流：没有关键词，翻页必须回传 [sessionId]（上游否则会换设备）。
  factory FeedState.feed({
    required List<T> items,
    int? nextOffset,
    String? sessionId,
  }) => FeedState<T>(
    mode: FeedMode.feed,
    query: '',
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
  );

  /// 搜索结果：关键词即上下文，翻页只带 offset。
  factory FeedState.search({
    required String query,
    required List<T> items,
    int? nextOffset,
  }) => FeedState<T>(
    mode: FeedMode.search,
    query: query,
    items: items,
    nextOffset: nextOffset,
  );

  final FeedMode mode;
  final String query;
  final List<T> items;

  /// 上游给的下一页游标，null 表示到底。
  final int? nextOffset;

  /// 推荐流的会话 id。只对推荐流有意义，搜索结果恒为 null。
  final String? sessionId;

  /// 是否正在加载下一页。既给底部 footer 用，也是控制器的并发守卫依据。
  final bool loadingMore;

  /// 加载下一页失败的文案；列表保留，只在底部提示重试。
  final String? loadMoreError;

  /// 这次翻页失败是否值得重试（来自 [ApiException.isRetryable]）。非瞬时的
  /// 失败（badInput / tooLarge / deviceFailed）重试同一个请求不会变好：底部
  /// 不给"重试"入口，控制器也不再发请求，避免用户点一次失败一次。
  final bool loadMoreRetryable;

  bool get isSearchMode => mode == FeedMode.search;
  bool get hasMore => nextOffset != null && nextOffset! > 0;
  bool get isEmpty => items.isEmpty;

  // 两个 with* 必须互相保留对方的字段：控制器里是链式调用
  // `withLoadingMore(true).withLoadMoreError(null)`，任何一边漏字段都会让
  // 并发守卫失效（真机上表现为同一 offset 每帧连发，列表被并发响应覆盖）。
  FeedState<T> withLoadingMore(bool value) => FeedState<T>(
    mode: mode,
    query: query,
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
    loadingMore: value,
    loadMoreError: loadMoreError,
    loadMoreRetryable: loadMoreRetryable,
  );

  FeedState<T> withLoadMoreError(String? message, {bool retryable = true}) =>
      FeedState<T>(
        mode: mode,
        query: query,
        items: items,
        nextOffset: nextOffset,
        sessionId: sessionId,
        loadingMore: loadingMore,
        loadMoreError: message,
        loadMoreRetryable: retryable,
      );

  /// 追加一页并按 id 去重：同一本书/同一部剧可能同时出现在多个推荐区块里。
  ///
  /// [idOf] 由调用方给（小说取 `NovelItem.id`，短剧取 `VideoSeries.id`）；
  /// 游标没前进就当作到底，避免同一个 offset 被反复请求把列表刷爆。
  FeedState<T> appendPage({
    required List<T> newItems,
    required String Function(T) idOf,
    int? nextOffset,
    String? sessionId,
  }) {
    final seen = <String>{for (final item in items) idOf(item)};
    final merged = List<T>.of(items);
    for (final item in newItems) {
      if (seen.add(idOf(item))) merged.add(item);
    }
    final advanced = nextOffset != null && nextOffset > (this.nextOffset ?? 0);
    return FeedState<T>(
      mode: mode,
      query: query,
      items: merged,
      nextOffset: advanced ? nextOffset : null,
      sessionId: sessionId ?? this.sessionId,
    );
  }

  /// 字段级相等：页面状态是否"内容没变"。列表按元素比较（元素模型的相等性
  /// 由 T 自己决定，推荐页的 `RecommendItem` 目前是恒等比较）。
  @override
  bool operator ==(Object other) =>
      other is FeedState<T> &&
      other.mode == mode &&
      other.query == query &&
      listEquals(other.items, items) &&
      other.nextOffset == nextOffset &&
      other.sessionId == sessionId &&
      other.loadingMore == loadingMore &&
      other.loadMoreError == loadMoreError &&
      other.loadMoreRetryable == loadMoreRetryable;

  @override
  int get hashCode => Object.hash(
    mode,
    query,
    Object.hashAll(items),
    nextOffset,
    sessionId,
    loadingMore,
    loadMoreError,
    loadMoreRetryable,
  );
}

/// 把异常变成可直接展示的一句话。
///
/// 文案策略集中在 [apiErrorCopy]：后端具体 message 优先，只有 "HTTP 500"
/// 这类技术兜底才换成 kind 短句；非 ApiException 用统一网络兜底。
String describeFeedError(Object error) =>
    apiErrorCopy(error, fallback: '网络开小差了，请稍后重试');
