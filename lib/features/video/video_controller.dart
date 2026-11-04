import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/api/api_client.dart';
import 'video_state.dart';

/// 当前视频搜索关键词；null 表示停留在推荐流。
final videoSearchQueryProvider =
    NotifierProvider<VideoSearchQueryController, String?>(
      VideoSearchQueryController.new,
    );

class VideoSearchQueryController extends Notifier<String?> {
  @override
  String? build() => null;

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

/// 视频 tab 数据。搜索/推荐互斥，切换通过 [videoSearchQueryProvider] 驱动。
final videoFeedControllerProvider =
    AsyncNotifierProvider<VideoFeedController, VideoFeedState>(
      VideoFeedController.new,
    );

class VideoFeedController extends AsyncNotifier<VideoFeedState> {
  VideoFeedState? _feedSnapshot;

  /// build 每重跑一次 +1：异步结果回来时对不上说明关键词已变，丢弃过期数据。
  int _generation = 0;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  FutureOr<VideoFeedState> build() {
    final query = ref.watch(videoSearchQueryProvider);
    _generation += 1;
    if (query != null && query.isNotEmpty) {
      return _loadSearch(query);
    }
    final snapshot = _feedSnapshot;
    if (snapshot != null) return snapshot;
    return _loadFeed();
  }

  Future<void> refresh() async {
    final query = ref.read(videoSearchQueryProvider);
    final current = state.value;
    final generation = _generation;

    if (current == null) {
      state = const AsyncLoading<VideoFeedState>();
      final next = await AsyncValue.guard(
        () => query == null ? _loadFeed() : _loadSearch(query),
      );
      if (generation != _generation) return;
      state = next;
      return;
    }

    // 已有内容时刷新失败只提示，不把列表换成错误页；异常交给页面 snackbar。
    final next = query == null ? await _loadFeed() : await _loadSearch(query);
    if (generation != _generation) return;
    state = AsyncData(next);
  }

  /// 滚动到底部时追加下一页；重复调用由 loadingMore/hasMore 挡掉。
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    final generation = _generation;
    state = AsyncData(current.withLoadingMore(true).withLoadMoreError(null));
    try {
      final page = current.isSearchMode
          ? await _api.searchVideos(
              current.query,
              offset: current.nextOffset ?? 0,
            )
          : await _api.videoFeed(
              offset: current.nextOffset ?? 0,
              sessionId: current.sessionId,
            );
      if (generation != _generation) return;
      state = AsyncData(current.withLoadingMore(false).appendPage(page));
    } catch (error) {
      if (generation != _generation) return;
      state = AsyncData(
        current
            .withLoadingMore(false)
            .withLoadMoreError(describeVideoError(error)),
      );
    }
  }

  void retryLoadMore() {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.withLoadMoreError(null));
    unawaited(loadMore());
  }

  Future<VideoFeedState> _loadFeed() async {
    final page = await _api.videoFeed();
    final snapshot = VideoFeedState.feed(
      items: page.items,
      nextOffset: page.nextOffset,
      sessionId: page.sessionId,
    );
    _feedSnapshot = snapshot;
    return snapshot;
  }

  Future<VideoFeedState> _loadSearch(String query) async {
    final page = await _api.searchVideos(query);
    return VideoFeedState.search(
      query: query,
      items: page.items,
      nextOffset: page.nextOffset,
    );
  }
}
