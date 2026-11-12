import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_client.dart';
import '../../data/models/json_utils.dart';
import 'recommend_category.dart';
import 'recommend_item.dart';
import 'recommend_state.dart';

/// 一个分类的推荐流。
///
/// family 按分类隔离：切分类时各自保留已加载的列表、游标与 session，不会
/// 因为切走再切回来重新冷启动。首屏失败走 AsyncError，翻页失败留在
/// [FeedState] 里（只影响底部提示，不清空列表）。
///
/// 搜索已经拆到独立搜索页（`lib/features/search/`），这里只负责推荐流：
/// 搜索词不再影响推荐页的列表，返回推荐页永远看到原来的内容。
final recommendFeedProvider =
    AsyncNotifierProvider.family<
      RecommendFeedController,
      RecommendState,
      RecommendCategory
    >(
      RecommendFeedController.new,
      // 关闭 Riverpod 3 的默认自动重试（10 次、约 38 秒）。重试期间状态是
      // 「isLoading=true + 上一次的 error」，页面会一直转圈、既看不到错误也点不到
      // 重试按钮；首屏失败应当立即给 ErrorView，由用户手动重试。
      retry: (retryCount, error) => null,
    );

class RecommendFeedController extends AsyncNotifier<RecommendState> {
  RecommendFeedController(this.category);

  final RecommendCategory category;

  /// build 每重跑一次 +1。异步结果回来时对不上，说明列表已经被 invalidate
  /// 重建过，丢弃过期数据，避免旧响应覆盖新列表。
  int _generation = 0;

  /// 列表"世代"：每次 [refresh] 开始 +1。
  ///
  /// 翻页请求发出时记下它，回来时对不上就说明列表已经被一次刷新整体换掉，
  /// 这一页是旧 session 的数据，必须丢弃——否则旧 session 的第二页会被
  /// append 到刷新后的新列表上（游标/session 不一致，列表错乱）。
  int _loadEpoch = 0;

  /// 刷新互斥：刷新期间不发翻页请求；也防止连续下拉并发两次刷新。
  ///
  /// 反向（翻页进行中刷新）允许：刷新会 bump [_loadEpoch]，把在途翻页的
  /// 结果作废，见 [loadMore]。
  bool _refreshing = false;

  /// 控制器级重入锁：状态里的 loadingMore 是给 UI 看的，这里再加一道，
  /// 防止同一帧内多次滚动/补屏调用把同一个 offset 并发发出去。
  bool _loadingMore = false;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  FutureOr<RecommendState> build() {
    _generation += 1;
    return _loadFeed();
  }

  /// 下拉刷新。
  ///
  /// 已有数据时刷新失败只把异常抛给页面提示，不替换当前内容；没有数据时
  /// 走和首屏一样的加载/错误路径。
  ///
  /// 刷新开始先把 [_loadEpoch] +1：刷新期间已经在途的 loadMore 返回时会被
  /// 判定为过期页并丢弃，避免旧 session 的第二页拼进刷新后的列表。
  Future<void> refresh() async {
    // 连续下拉只跑一次：两个 refresh 响应互相覆盖没有意义。
    if (_refreshing) return;
    _refreshing = true;
    _loadEpoch += 1;
    final generation = _generation;
    try {
      final current = state.value;

      if (current == null) {
        state = const AsyncLoading<RecommendState>();
        final next = await AsyncValue.guard(_loadFeed);
        if (generation != _generation) return;
        state = next;
        return;
      }

      final fresh = await _fetchFeed();
      if (generation != _generation) return;
      state = AsyncData(fresh);
    } finally {
      _refreshing = false;
    }
  }

  /// 滚动到底时追加下一页。
  ///
  /// 重复请求在入口处就被状态挡掉：正在加载、已到底、上次失败还没重试，
  /// 都不发新请求。翻页失败只更新底部提示，不清空已加载的列表。
  ///
  /// 刷新期间不发翻页（整条列表会被刷新替换，此时翻页只会拿到旧 session 的
  /// 页）；翻页期间允许刷新，翻页响应回来时用 [_loadEpoch] 判定并丢弃。
  Future<void> loadMore() async {
    if (_refreshing) return;
    final current = state.value;
    if (_loadingMore ||
        current == null ||
        current.loadingMore ||
        !current.hasMore) {
      return;
    }
    if (current.loadMoreError != null) return;

    final generation = _generation;
    final epoch = _loadEpoch;
    _loadingMore = true;
    state = AsyncData(current.withLoadingMore(true));
    try {
      final offset = current.nextOffset!;
      // 翻页请求的分类差异（含漫剧无游标时改走搜索兜底）都在 ContentSource 里。
      final page = await _fetchFeed(
        offset: offset,
        sessionId: current.sessionId,
      );
      if (_isStale(generation, epoch)) {
        _dropStaleLoadingMore();
        return;
      }
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(
        latest.appendPage(
          newItems: page.items,
          idOf: (item) => item.id,
          nextOffset: page.nextOffset,
          sessionId: page.sessionId,
        ),
      );
    } catch (error) {
      if (_isStale(generation, epoch)) {
        _dropStaleLoadingMore();
        return;
      }
      final latest = state.value;
      if (latest == null) return;
      // 失败时把 loadingMore 收回来：footer 先判 loadingMore 再判 error，
      // 不收回来会永远停在转圈，用户既看不到错误也没有重试入口。
      state = AsyncData(
        latest
            .withLoadingMore(false)
            .withLoadMoreError(
              describeFeedError(error),
              retryable: isRetryableError(error),
            ),
      );
    } finally {
      _loadingMore = false;
    }
  }

  /// 翻页请求是否已被刷新/重建取代（代际或列表世代对不上）。
  bool _isStale(int generation, int epoch) =>
      generation != _generation || epoch != _loadEpoch;

  /// 被取代的翻页把"翻页中"收回来：刷新失败时 state 可能还停在
  /// `withLoadingMore(true)` 那一份，不清掉 footer 会一直转圈。
  void _dropStaleLoadingMore() {
    final latest = state.value;
    if (latest != null && latest.loadingMore) {
      state = AsyncData(latest.withLoadingMore(false));
    }
  }

  /// 底部"加载失败"重试：先清掉失败标记，再走一次正常的追加流程。
  Future<void> retryLoadMore() async {
    final current = state.value;
    if (current == null || current.loadMoreError == null) return;
    // 非瞬时失败（badInput / tooLarge / deviceFailed）重试同一个请求不会变好，
    // 直接不发；底部也不会给重试入口（见 FeedFooter.retryable）。
    if (!current.loadMoreRetryable) return;
    state = AsyncData(current.withLoadMoreError(null));
    await loadMore();
  }

  Future<RecommendState> _loadFeed() => _fetchFeed();

  /// 推荐流的一页。分类 → 上游请求的差异（tab、漫剧兜底）全在
  /// [RecommendCategory.source] 里。
  Future<RecommendState> _fetchFeed({int offset = 0, String? sessionId}) async {
    final page = await category.source.feed(
      _api,
      offset: offset,
      sessionId: sessionId,
    );
    return FeedState<RecommendItem>(
      items: page.items,
      nextOffset: page.nextOffset,
      sessionId: page.sessionId,
    );
  }
}
