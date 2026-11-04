import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/feed/feed_grid.dart';
import '../../app/feed/feed_search_field.dart';
import '../../app/feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/states.dart';
import '../../data/models/novel_item.dart';
import 'recommend_controller.dart';
import 'recommend_state.dart';
import 'widgets/recommend_results_sliver.dart';

/// 小说推荐页：顶部搜索框 + 三列推荐流；提交搜索后同一页切成结果列表。
///
/// 页面只保留输入框/焦点这类 UI 状态；列表数据全部在
/// [recommendControllerProvider] 里，切 tab、搜索往返都不丢已加载的内容。
/// 滚动/翻页/下拉刷新/空态这些通用行为交给 [FeedView]。
class RecommendPage extends ConsumerStatefulWidget {
  const RecommendPage({super.key});

  @override
  ConsumerState<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends ConsumerState<RecommendPage> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 页面可能因切 tab 重建，但 provider 里的关键词还在：回填输入框，
    // 否则会看到"结果列表 + 空搜索框"的错位状态。
    final query = ref.read(searchQueryProvider);
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
    final active = ref.read(searchQueryProvider);
    if (active == query) {
      // 同一个关键词再次提交视为重试（例如上次请求失败）。
      ref.invalidate(recommendControllerProvider);
      return;
    }
    ref.read(searchQueryProvider.notifier).submit(query);
  }

  /// 清空输入：如果已经在搜索结果里，还要退回推荐流。
  void _clearSearchInput() {
    _searchController.clear();
    if (ref.read(searchQueryProvider) != null) {
      ref.read(searchQueryProvider.notifier).cancel();
    }
  }

  void _cancelSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    ref.read(searchQueryProvider.notifier).cancel();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(recommendControllerProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeFeedError(error))));
    }
  }

  void _retry() => ref.invalidate(recommendControllerProvider);

  void _retryLoadMore() =>
      ref.read(recommendControllerProvider.notifier).retryLoadMore();

  void _openDetail(NovelItem item) {
    Navigator.of(context).pushNamed(
      AppRoutes.detail,
      arguments: DetailArgs(bookId: item.id, preview: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(recommendControllerProvider);
    final activeQuery = ref.watch(searchQueryProvider);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: FeedSearchField(
              controller: _searchController,
              focusNode: _searchFocus,
              hintText: '搜索书名/作者',
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

  Widget _buildBody(AsyncValue<RecommendState> async, String? activeQuery) {
    final data = async.value;

    // 关键词已提交但结果还没回来：整页只留加载/错误，避免旧推荐流或上一个
    // 关键词的结果闪一下再消失；错误时也保留顶部搜索框，用户仍能取消回到
    // 推荐流。
    if (activeQuery != null &&
        (data == null || !data.isSearchMode || data.query != activeQuery)) {
      if (async.hasError) {
        return ErrorView(
          message: describeFeedError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '搜索中…');
    }

    if (data == null) {
      if (async.hasError) {
        return ErrorView(
          message: describeFeedError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '正在加载推荐');
    }

    final isSearch = data.isSearchMode;
    return FeedView<NovelItem>(
      state: data,
      title: isSearch ? '搜索结果' : '为你推荐',
      subtitle: isSearch ? '${data.query} · ${_countLabel(data)}' : null,
      onRefresh: _refresh,
      onLoadMore: () => ref.read(recommendControllerProvider.notifier).loadMore(),
      onRetryLoadMore: _retryLoadMore,
      emptyMessage: isSearch
          ? '没有找到「${data.query}」\n换个书名或作者再试试'
          : '暂时没有推荐内容\n下拉刷新试试',
      emptyIcon: isSearch
          ? Icons.search_off_rounded
          : Icons.auto_stories_outlined,
      sliverBuilder: (context, state) {
        if (state.isSearchMode) {
          return RecommendResultsSliver(items: state.items, onTap: _openDetail);
        }
        final metrics = FeedGridMetrics.of(context, coverAspect: 1.38);
        return FeedGrid<NovelItem>(
          items: state.items,
          metrics: metrics,
          itemBuilder: (context, item, width) => NovelGridCard(
            key: ValueKey(item.id),
            item: item,
            width: width,
            onTap: () => _openDetail(item),
          ),
        );
      },
    );
  }

  /// 还没到底时说"已加载"，到底了才说"共"：避免用户把已加载数当成总数。
  String _countLabel(RecommendState data) {
    final count = data.items.length;
    return data.hasMore ? '已加载 $count 本' : '共 $count 本';
  }
}
