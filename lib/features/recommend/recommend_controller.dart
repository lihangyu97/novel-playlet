import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_client.dart';
import 'recommend_state.dart';

/// 当前搜索关键词；null 表示停留在推荐流。
///
/// 单独抽成一个 Notifier：搜索结果 controller 用 `ref.watch` 监听它，提交/
/// 取消搜索就只是改这一个值，页面不用手动触发重新加载，也不会在两个页面
/// 状态之间手动同步"现在是搜索模式吗"。
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

/// 推荐页数据。首屏失败走 AsyncError，翻页失败留在 RecommendState 里。
final recommendControllerProvider =
    AsyncNotifierProvider<RecommendController, RecommendState>(
      RecommendController.new,
    );

class RecommendController extends AsyncNotifier<RecommendState> {
  /// 推荐流快照：取消搜索时直接回显，不让"返回"再等一次冷启动请求。
  RecommendState? _feedSnapshot;

  /// build 每重跑一次 +1。异步结果回来时对不上，说明关键词已经变了，
  /// 丢弃过期数据，避免"搜索 A 的结果覆盖搜索 B"。
  int _generation = 0;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  FutureOr<RecommendState> build() {
    final query = ref.watch(searchQueryProvider);
    _generation += 1;
    if (query != null && query.isNotEmpty) {
      return _loadSearch(query);
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
        () => query == null ? _loadFeed() : _loadSearch(query),
      );
      if (generation != _generation) return;
      state = next;
      return;
    }

    if (current.isSearchMode) {
      final page = await _api.search(current.query);
      if (generation != _generation) return;
      state = AsyncData(
        RecommendState.search(
          query: current.query,
          items: page.items,
          nextOffset: page.nextOffset,
        ),
      );
      return;
    }

    // 推荐流刷新从 offset 0 重新开一个 session，不带旧 sessionId。
    final page = await _api.recommend();
    if (generation != _generation) return;
    final fresh = RecommendState.feed(
      items: page.items,
      nextOffset: page.nextOffset,
      sessionId: page.sessionId,
    );
    _feedSnapshot = fresh;
    state = AsyncData(fresh);
  }

  /// 滚动到底时追加下一页。
  ///
  /// 重复请求在入口处就被状态挡掉：正在加载、已到底、上次失败还没重试，
  /// 都不发新请求。翻页失败只更新底部提示，不清空已加载的列表。
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.loadingMore || !current.hasMore) return;
    if (current.loadMoreError != null) return;

    final generation = _generation;
    state = AsyncData(current.withLoadingMore(true));
    try {
      final page = current.isSearchMode
          ? await _api.search(current.query, offset: current.nextOffset!)
          : await _api.recommend(
              offset: current.nextOffset!,
              sessionId: current.sessionId,
            );
      if (generation != _generation) return;
      final latest = state.value;
      if (latest == null) return;
      final next = latest.appendPage(page);
      state = AsyncData(next);
      if (!next.isSearchMode) _feedSnapshot = next;
    } catch (error) {
      if (generation != _generation) return;
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(latest.withLoadMoreError(describeFeedError(error)));
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
    final page = await _api.recommend();
    final snapshot = RecommendState.feed(
      items: page.items,
      nextOffset: page.nextOffset,
      sessionId: page.sessionId,
    );
    _feedSnapshot = snapshot;
    return snapshot;
  }

  Future<RecommendState> _loadSearch(String query) async {
    final page = await _api.search(query);
    return RecommendState.search(
      query: query,
      items: page.items,
      nextOffset: page.nextOffset,
    );
  }
}
