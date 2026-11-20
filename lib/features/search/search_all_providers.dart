import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/json_utils.dart' show isRetryableError;
import '../feed/feed_state.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_item.dart';

/// 「查看全部」结果页的列表状态（按 id 去重、游标、翻页失败都复用通用
/// [FeedState]）。
typedef SearchAllState = FeedState<RecommendItem>;

/// 一次「查看全部」的身份：分类 + 关键词。
///
/// 和 `SearchRequest` 一样把关键词放进 family 参数：换词就是换一个 provider
/// 实例，旧关键词迟到的响应写不回新页面；autoDispose 让页面关掉即回收。
@immutable
class SearchAllRequest {
  const SearchAllRequest({required this.category, required this.query});

  final RecommendCategory category;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is SearchAllRequest &&
      other.category == category &&
      other.query == query;

  @override
  int get hashCode => Object.hash(category, query);
}

/// 某个分类的完整搜索结果（首屏 + 翻页）。
///
/// 关闭 Riverpod 3 的默认自动重试：搜索失败要立刻给「重试」入口，而不是在
/// 后台转圈 38 秒。
final searchAllProvider = AsyncNotifierProvider.autoDispose
    .family<SearchAllController, SearchAllState, SearchAllRequest>(
      SearchAllController.new,
      retry: (retryCount, error) => null,
    );

class SearchAllController extends AsyncNotifier<SearchAllState> {
  SearchAllController(this.request);

  final SearchAllRequest request;

  /// 控制器级并发锁：列表状态里的 `loadingMore` 是给 UI 看的，滚动通知和补屏
  /// 检查可能在同一帧各调一次 [loadMore]，没有这道锁会把同一个 offset 发两遍。
  bool _loadingMore = false;

  @override
  Future<SearchAllState> build() async {
    final page = await request.category.source.search(
      ref.read(apiClientProvider),
      request.query,
    );
    return FeedState(items: page.items, nextOffset: page.nextOffset);
  }

  /// 加载下一页。
  ///
  /// 游标只认「下一页是否前进」（[FeedState.appendPage] 里判断），上游返回的
  /// has_more 不可信；页间重复条目按 id 去重，搜索响应确实会出现同一部剧
  /// 跨页重复。失败只写进 `loadMoreError`：已经加载出来的结果不清空，底部由
  /// `FeedFooter` 给「重试」，确定性失败（badInput 等）不给重试入口。
  Future<void> loadMore() async {
    final current = state.value;
    final offset = current?.nextOffset;
    if (current == null || offset == null || _loadingMore) return;

    _loadingMore = true;
    state = AsyncData(current.withLoadingMore(true).withLoadMoreError(null));
    try {
      final page = await request.category.source.search(
        ref.read(apiClientProvider),
        request.query,
        offset: offset,
      );
      final latest = state.value;
      if (!ref.mounted || latest == null) return;
      state = AsyncData(
        latest
            .appendPage(
              newItems: page.items,
              idOf: _idOf,
              nextOffset: page.nextOffset,
            )
            .withLoadingMore(false)
            .withLoadMoreError(null),
      );
    } catch (error) {
      final latest = state.value;
      if (!ref.mounted || latest == null) return;
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
}

/// 去重键带内容域前缀：小说的书 id 和短剧的剧 id 不是同一个命名空间。
String _idOf(RecommendItem item) => switch (item) {
  NovelRecommendItem(:final novel) => 'novel-${novel.id}',
  VideoRecommendItem(:final video) => 'video-${video.id}',
};
