import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_client.dart';
import 'recommend_category.dart';
import 'recommend_item.dart';
import 'recommend_state.dart';

/// 推荐页当前搜索关键词；null 表示停留在推荐流。
///
/// 三个分类共用一个搜索词：提交后各分类按自己的搜索 `tab_type` 取结果，
/// 切换分类时搜索词和结果都还在；取消搜索只是改这一个值，各分类自动回显
/// 自己的推荐流快照。
final searchQueryProvider = NotifierProvider<SearchQueryController, String?>(
  SearchQueryController.new,
);

class SearchQueryController extends Notifier<String?> {
  @override
  String? build() => null;

  /// 提交搜索；空关键词等同取消。
  void submit(String raw) {
    final query = raw.trim();
    if (query.isEmpty) {
      cancel();
      return;
    }
    state = query;
  }

  void cancel() => state = null;
}

/// 一个分类的推荐/搜索流。
///
/// family 按分类隔离：切分类时各自保留已加载的列表、游标与 session，不会
/// 因为切走再切回来重新冷启动。首屏失败走 AsyncError，翻页失败留在
/// [FeedState] 里（只影响底部提示，不清空列表）。
final recommendFeedProvider = AsyncNotifierProvider.family<
  RecommendFeedController,
  RecommendState,
  RecommendCategory
>(RecommendFeedController.new);

class RecommendFeedController extends AsyncNotifier<RecommendState> {
  RecommendFeedController(this.category);

  final RecommendCategory category;

  /// 推荐流快照：取消搜索时直接回显，不让"返回"再等一次冷启动请求。
  RecommendState? _feedSnapshot;

  /// build 每重跑一次 +1。异步结果回来时对不上，说明关键词已经变了，
  /// 丢弃过期数据，避免"搜索 A 的结果覆盖搜索 B"。
  int _generation = 0;

  /// 控制器级重入锁：状态里的 loadingMore 是给 UI 看的，这里再加一道，
  /// 防止同一帧内多次滚动/补屏调用把同一个 offset 并发发出去。
  bool _loadingMore = false;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  FutureOr<RecommendState> build() {
    final query = ref.watch(searchQueryProvider);
    _generation += 1;
    if (query != null && query.isNotEmpty) {
      return _fetchSearch(query);
    }
    final snapshot = _feedSnapshot;
    if (snapshot != null) return snapshot;
    return _loadFeed();
  }

  /// 下拉刷新。
  ///
  /// 已有数据时刷新失败只把异常抛给页面提示，不替换当前内容；没有数据时
  /// 走和首屏一样的加载/错误路径。
  Future<void> refresh() async {
    final query = ref.read(searchQueryProvider);
    final current = state.value;
    final generation = _generation;

    if (current == null) {
      state = const AsyncLoading<RecommendState>();
      final next = await AsyncValue.guard(
        () => query == null ? _loadFeed() : _fetchSearch(query),
      );
      if (generation != _generation) return;
      state = next;
      return;
    }

    final fresh = query == null
        ? await _fetchFeed()
        : await _fetchSearch(query);
    if (generation != _generation) return;
    if (query == null) _feedSnapshot = fresh;
    state = AsyncData(fresh);
  }

  /// 滚动到底时追加下一页。
  ///
  /// 重复请求在入口处就被状态挡掉：正在加载、已到底、上次失败还没重试，
  /// 都不发新请求。翻页失败只更新底部提示，不清空已加载的列表。
  Future<void> loadMore() async {
    final current = state.value;
    if (_loadingMore ||
        current == null ||
        current.loadingMore ||
        !current.hasMore) {
      return;
    }
    if (current.loadMoreError != null) return;

    final generation = _generation;
    _loadingMore = true;
    state = AsyncData(current.withLoadingMore(true));
    try {
      final offset = current.nextOffset!;
      final page = current.isSearchMode
          ? await _fetchSearch(current.query, offset: offset)
          : await _fetchFeed(offset: offset, sessionId: current.sessionId);
      if (generation != _generation) return;
      final latest = state.value;
      if (latest == null) return;
      final next = latest.appendPage(
        newItems: page.items,
        idOf: (item) => item.id,
        nextOffset: page.nextOffset,
        sessionId: page.sessionId,
      );
      state = AsyncData(next);
      if (!next.isSearchMode) _feedSnapshot = next;
    } catch (error) {
      if (generation != _generation) return;
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(latest.withLoadMoreError(describeFeedError(error)));
    } finally {
      _loadingMore = false;
    }
  }

  /// 底部"加载失败"重试：先清掉失败标记，再走一次正常的追加流程。
  Future<void> retryLoadMore() async {
    final current = state.value;
    if (current == null || current.loadMoreError == null) return;
    state = AsyncData(current.withLoadMoreError(null));
    await loadMore();
  }

  Future<RecommendState> _loadFeed() async {
    final fresh = await _fetchFeed();
    _feedSnapshot = fresh;
    return fresh;
  }

  /// 推荐流的一页。小说走书籍首页接口，短剧/漫剧共用视频类接口（按 tab_type）。
  Future<RecommendState> _fetchFeed({
    int offset = 0,
    String? sessionId,
  }) async {
    if (category.isNovel) {
      final page = await _api.recommend(offset: offset, sessionId: sessionId);
      return FeedState<RecommendItem>.feed(
        items: [for (final item in page.items) RecommendItem.novel(item)],
        nextOffset: page.nextOffset,
        sessionId: page.sessionId,
      );
    }
    final page = await _api.videoFeed(
      tabType: category.tabType,
      offset: offset,
      sessionId: sessionId,
    );
    return FeedState<RecommendItem>.feed(
      items: [for (final item in page.items) RecommendItem.video(item)],
      nextOffset: page.nextOffset,
      sessionId: page.sessionId,
    );
  }

  Future<RecommendState> _fetchSearch(String query, {int offset = 0}) async {
    if (category.isNovel) {
      final page = await _api.search(query, offset: offset);
      return FeedState<RecommendItem>.search(
        query: query,
        items: [for (final item in page.items) RecommendItem.novel(item)],
        nextOffset: page.nextOffset,
      );
    }
    final page = await _api.searchVideos(
      query,
      tabType: category.searchTabType,
      offset: offset,
    );
    return FeedState<RecommendItem>.search(
      query: query,
      items: [for (final item in page.items) RecommendItem.video(item)],
      nextOffset: page.nextOffset,
    );
  }
}
