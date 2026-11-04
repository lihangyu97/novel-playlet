import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/feed/feed_grid.dart';
import '../../app/feed/feed_search_field.dart';
import '../../app/feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/states.dart';
import '../../data/models/video_series.dart';
import 'video_controller.dart';
import 'video_state.dart';
import 'widgets/video_card.dart';

/// 短剧 tab：顶部搜索框 + 短剧推荐流；提交搜索后同页切成结果列表。
///
/// 结构与小说推荐页一致（搜索/列表共用一个 controller），卡片与业务不同；
/// 滚动/翻页/空态等通用行为交给 [FeedView]。短剧页按需求**没有下拉刷新**。
class VideoPage extends ConsumerStatefulWidget {
  const VideoPage({super.key});

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 页面可能因切 tab 重建，但 provider 里的关键词还在：回填输入框，
    // 否则会出现"结果列表 + 空搜索框"的错位。
    final query = ref.read(videoSearchQueryProvider);
    if (query != null) _searchController.text = query;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    _searchFocus.unfocus();
    if (query.isEmpty) {
      _cancelSearch();
      return;
    }
    if (ref.read(videoSearchQueryProvider) == query) {
      // 同一关键词再次提交 = 重试。
      ref.invalidate(videoFeedControllerProvider);
      return;
    }
    ref.read(videoSearchQueryProvider.notifier).submit(query);
  }

  void _clearSearchInput() {
    _searchController.clear();
    if (ref.read(videoSearchQueryProvider) != null) {
      ref.read(videoSearchQueryProvider.notifier).cancel();
    }
  }

  void _cancelSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    ref.read(videoSearchQueryProvider.notifier).cancel();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(videoFeedControllerProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeVideoError(error))));
    }
  }

  void _retry() => ref.invalidate(videoFeedControllerProvider);

  void _retryLoadMore() =>
      ref.read(videoFeedControllerProvider.notifier).retryLoadMore();

  void _openDetail(VideoSeries item) {
    Navigator.of(context).pushNamed(
      AppRoutes.videoDetail,
      arguments: VideoDetailArgs(seriesId: item.id, preview: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(videoFeedControllerProvider);
    final activeQuery = ref.watch(videoSearchQueryProvider);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: FeedSearchField(
              controller: _searchController,
              focusNode: _searchFocus,
              hintText: '搜短剧',
              onSubmitted: _submitSearch,
              onClear: _clearSearchInput,
              onCancel: _cancelSearch,
              showCancel: activeQuery != null,
            ),
          ),
          Expanded(child: _buildBody(async, activeQuery)),
        ],
      ),
    );
  }

  Widget _buildBody(AsyncValue<VideoFeedState> async, String? activeQuery) {
    final data = async.value;

    // 关键词已提交但结果还没回来：整页只留加载/错误，避免旧推荐流闪一下。
    if (activeQuery != null &&
        (data == null || !data.isSearchMode || data.query != activeQuery)) {
      if (async.hasError) {
        return ErrorView(
          message: describeVideoError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '搜索中…');
    }

    if (data == null) {
      if (async.hasError) {
        return ErrorView(
          message: describeVideoError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '正在加载短剧');
    }

    final isSearch = data.isSearchMode;
    return FeedView<VideoSeries>(
      state: data,
      title: isSearch ? '搜索结果' : '短剧推荐',
      subtitle: isSearch ? '${data.query} · ${data.items.length} 部' : null,
      // 两个推荐页都保留下拉刷新；搜索框在 FeedView 外面固定不动，
      // 只有下面的内容区随手下滑、松开刷新。
      onRefresh: _refresh,
      onLoadMore: () => ref.read(videoFeedControllerProvider.notifier).loadMore(),
      onRetryLoadMore: _retryLoadMore,
      emptyMessage: isSearch
          ? '没有找到「${data.query}」\n换个剧名再试试'
          : '暂时没有短剧推荐\n下拉刷新试试',
      emptyIcon: isSearch ? Icons.search_off_rounded : Icons.movie_outlined,
      sliverBuilder: (context, state) {
        final metrics = FeedGridMetrics.of(context);
        return FeedGrid<VideoSeries>(
          items: state.items,
          metrics: metrics,
          itemBuilder: (context, item, width) => VideoCard(
            key: ValueKey(item.id),
            item: item,
            width: width,
            onTap: () => _openDetail(item),
          ),
        );
      },
    );
  }
}
