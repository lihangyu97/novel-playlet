import 'package:flutter/foundation.dart';

import '../../data/models/json_utils.dart';
import '../../data/models/video_series.dart';

/// 视频页当前展示的是推荐流还是搜索结果。
enum VideoFeedMode { feed, search }

/// 视频页数据快照。
///
/// 与小说推荐页同一套约定：首屏加载/失败由 AsyncValue 承载，这里只描述
/// "已有数据、正在追加下一页"这类页面内状态，翻页失败不清空已展示卡片。
@immutable
class VideoFeedState {
  const VideoFeedState._({
    required this.mode,
    required this.query,
    required this.items,
    this.nextOffset,
    this.sessionId,
    this.loadingMore = false,
    this.loadMoreError,
  });

  factory VideoFeedState.feed({
    required List<VideoSeries> items,
    int? nextOffset,
    String? sessionId,
  }) => VideoFeedState._(
    mode: VideoFeedMode.feed,
    query: '',
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
  );

  factory VideoFeedState.search({
    required String query,
    required List<VideoSeries> items,
    int? nextOffset,
  }) => VideoFeedState._(
    mode: VideoFeedMode.search,
    query: query,
    items: items,
    nextOffset: nextOffset,
  );

  final VideoFeedMode mode;
  final String query;
  final List<VideoSeries> items;
  final int? nextOffset;
  final String? sessionId;
  final bool loadingMore;
  final String? loadMoreError;

  bool get isSearchMode => mode == VideoFeedMode.search;

  bool get hasMore => nextOffset != null && nextOffset! > 0;

  // 两个 with* 必须互相保留对方的字段：loadMore 里是链式调用
  // `withLoadingMore(true).withLoadMoreError(null)`，之前后者把 loadingMore
  // 重置成 false，导致并发守卫失效、同一 offset 被连发上百次。
  VideoFeedState withLoadingMore(bool value) => VideoFeedState._(
    mode: mode,
    query: query,
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
    loadingMore: value,
    loadMoreError: loadMoreError,
  );

  VideoFeedState withLoadMoreError(String? message) => VideoFeedState._(
    mode: mode,
    query: query,
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
    loadingMore: loadingMore,
    loadMoreError: message,
  );

  /// 追加一页并按 id 去重：同一部剧可能同时出现在多个推荐区块里。
  VideoFeedState appendPage(VideoFeedPage page) {
    final seen = <String>{for (final item in items) item.id};
    final merged = List<VideoSeries>.of(items);
    for (final item in page.items) {
      if (seen.add(item.id)) merged.add(item);
    }
    final advanced =
        page.nextOffset != null && page.nextOffset! > (nextOffset ?? 0);
    return VideoFeedState._(
      mode: mode,
      query: query,
      items: merged,
      nextOffset: advanced ? page.nextOffset : null,
      sessionId: page.sessionId ?? sessionId,
    );
  }
}

/// 把异常变成可直接展示的一句话；[ApiException] 的 message 已经是人话。
String describeVideoError(Object error) {
  if (error is ApiException) return error.message;
  return '网络开小差了，请稍后重试';
}
