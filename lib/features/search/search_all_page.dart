import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/states.dart';
import '../feed/feed_state.dart';
import '../feed/feed_staggered_grid.dart';
import '../feed/feed_view.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_item.dart';
import '../recommend/recommend_layout.dart';
import 'search_all_providers.dart';
import 'search_result_card.dart';

/// 某个分类的完整搜索结果页（搜索页每行「查看全部」进来的）。
///
/// 搜索页那两行是横滑预览（一屏 2.5 张、只取首屏一页），这里换成竖向瀑布流
/// 并接上 `offset` 翻页：列表骨架、滚动到底加载、底部「重试」、空态全部复用
/// 首页流的 [FeedView] / [FeedStaggeredGrid]，不另写一套分页。
///
/// 列数跟设置里的推荐流布局走（双列 / 三列）：同一个 App 里卡片密度保持一致。
class SearchAllPage extends ConsumerWidget {
  const SearchAllPage({super.key, required this.category, required this.query});

  final RecommendCategory category;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = SearchAllRequest(category: category, query: query);
    final async = ref.watch(searchAllProvider(request));
    final columns = ref.watch(recommendLayoutProvider).columns;
    // Hero tag 带页面维度：同一本书可能同时出现在搜索页行内和这里。
    final heroSource = 'search-all-${category.name}';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '“$query” · ${category.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: switch (async) {
        AsyncData(:final value) => FeedView<RecommendItem>(
          state: value,
          onLoadMore: () =>
              ref.read(searchAllProvider(request).notifier).loadMore(),
          onRetryLoadMore: () =>
              ref.read(searchAllProvider(request).notifier).loadMore(),
          emptyMessage: '没有找到相关${category.label}',
          emptyIcon: category.emptyIcon,
          sliverBuilder: (context, state) => FeedStaggeredGrid<RecommendItem>(
            items: state.items,
            columns: columns,
            itemBuilder: (context, item, width) => SearchResultCard(
              item: item,
              width: width,
              heroSource: heroSource,
              naturalTitleHeight: true,
              onTap: () =>
                  openSearchResult(context, item, heroSource: heroSource),
            ),
          ),
        ),
        AsyncError(:final error) => ErrorView(
          message: describeFeedError(error),
          onRetry: () => ref.invalidate(searchAllProvider(request)),
        ),
        _ => const LoadingView(),
      },
    );
  }
}
