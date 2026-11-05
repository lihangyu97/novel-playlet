import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/feed/feed_grid.dart';
import '../../app/feed/feed_results.dart';
import '../../app/feed/feed_search_field.dart';
import '../../app/feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/states.dart';
import '../video/widgets/video_card.dart';
import 'recommend_category.dart';
import 'recommend_controller.dart';
import 'recommend_item.dart';
import 'recommend_state.dart';

/// 合并后的「推荐」页：顶部搜索框 + 可左右滑动的分类 tabs + 每个分类一条流。
///
/// 以前小说/短剧是底部两个 tab、各自一套搜索框和页面状态；合并后分类变成
/// 搜索框下方的一级 tabs，三个分类共用同一个搜索词，各自保留自己的列表、
/// 游标与滚动位置。分类 tabs 与内容都支持左右滑动（`TabBar(isScrollable)` +
/// `TabBarView`）。
///
/// 页面只保留输入框/焦点这类 UI 状态；列表数据全部在
/// [recommendFeedProvider] 里，切分类、搜索往返都不丢已加载的内容。
class RecommendPage extends ConsumerStatefulWidget {
  const RecommendPage({super.key});

  @override
  ConsumerState<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends ConsumerState<RecommendPage>
    with SingleTickerProviderStateMixin {
  static const _categories = RecommendCategory.values;

  late final TabController _tabController = TabController(
    length: _categories.length,
    vsync: this,
  );
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  RecommendCategory get _activeCategory => _categories[_tabController.index];

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
    _tabController.dispose();
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
      ref.invalidate(recommendFeedProvider(_activeCategory));
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

  @override
  Widget build(BuildContext context) {
    final activeQuery = ref.watch(searchQueryProvider);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            // 提示文案跟着当前分类走；AnimatedBuilder 同时让左右滑动切分类时
            // 提示词及时更新。
            child: AnimatedBuilder(
              animation: _tabController,
              builder: (context, _) => FeedSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                hintText: _activeCategory.searchHint,
                onSubmitted: _submitSearch,
                onClear: _clearSearchInput,
                onCancel: _cancelSearch,
                showCancel: activeQuery != null,
              ),
            ),
          ),
          _buildCategoryTabs(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final category in _categories)
                  _CategoryFeedPage(
                    key: ValueKey(category),
                    category: category,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分类 tabs：横向可滚动、左对齐。只有 3 个分类时一屏放得下，但后续加
  /// 分类（听书/漫画）不需要再改布局。
  Widget _buildCategoryTabs(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(width: 3, color: scheme.primary),
        insets: const EdgeInsets.symmetric(horizontal: 4),
      ),
      dividerColor: Colors.transparent,
      tabs: [for (final category in _categories) Tab(text: category.label)],
    );
  }
}

/// 单个分类的流（推荐/搜索共用）。
///
/// 用 [AutomaticKeepAliveClientMixin] 保活：TabBarView 滚出屏幕后会销毁子树，
/// 保活才能让每个分类的滚动位置在左右滑动切回时原样保留。
class _CategoryFeedPage extends ConsumerStatefulWidget {
  const _CategoryFeedPage({super.key, required this.category});

  final RecommendCategory category;

  @override
  ConsumerState<_CategoryFeedPage> createState() => _CategoryFeedPageState();
}

class _CategoryFeedPageState extends ConsumerState<_CategoryFeedPage>
    with AutomaticKeepAliveClientMixin {
  RecommendCategory get _category => widget.category;

  @override
  bool get wantKeepAlive => true;

  RecommendFeedController get _controller =>
      ref.read(recommendFeedProvider(_category).notifier);

  Future<void> _refresh() async {
    try {
      await _controller.refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeFeedError(error))));
    }
  }

  void _retry() => ref.invalidate(recommendFeedProvider(_category));

  void _retryLoadMore() => _controller.retryLoadMore();

  void _openDetail(RecommendItem item) {
    final novel = item.novel;
    if (novel != null) {
      Navigator.of(context).pushNamed(
        AppRoutes.detail,
        arguments: DetailArgs(bookId: novel.id, preview: novel),
      );
      return;
    }
    final video = item.video!;
    Navigator.of(context).pushNamed(
      AppRoutes.videoDetail,
      arguments: VideoDetailArgs(seriesId: video.id, preview: video),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final async = ref.watch(recommendFeedProvider(_category));
    final activeQuery = ref.watch(searchQueryProvider);
    final data = async.value;

    // 关键词已提交但结果还没回来：整页只留加载/错误，避免旧推荐流或上一个
    // 关键词的结果闪一下再消失；错误时也保留顶部搜索框，用户仍能取消回到
    // 推荐流。
    // 先判 isLoading 再判 hasError：Riverpod 3 的 AsyncLoading 会带上一次
    // error（copyWithPrevious），换关键词/点重试期间 hasError 仍为 true，
    // 先判 error 会把旧的错误页一直钉在屏幕上，看起来像没反应。
    if (activeQuery != null &&
        (data == null || !data.isSearchMode || data.query != activeQuery)) {
      if (async.isLoading) return const LoadingView(label: '搜索中…');
      if (async.hasError) {
        return ErrorView(
          message: describeFeedError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '搜索中…');
    }

    if (data == null) {
      if (async.isLoading) {
        return LoadingView(label: '正在加载${_category.label}');
      }
      if (async.hasError) {
        return ErrorView(
          message: describeFeedError(async.error!),
          onRetry: _retry,
        );
      }
      return LoadingView(label: '正在加载${_category.label}');
    }

    final isSearch = data.isSearchMode;
    return FeedView<RecommendItem>(
      state: data,
      // 合并后分类本身就是标题，推荐态不再显示「为你推荐 / 短剧推荐」；
      // 搜索态保留「搜索结果」便于区分。
      title: isSearch ? '搜索结果' : null,
      onRefresh: _refresh,
      onLoadMore: _controller.loadMore,
      onRetryLoadMore: _retryLoadMore,
      emptyMessage: isSearch
          ? '没有找到「${data.query}」\n换个关键词再试试'
          : '暂时没有${_category.label}推荐\n下拉刷新试试',
      emptyIcon: isSearch ? Icons.search_off_rounded : _category.emptyIcon,
      sliverBuilder: (context, state) {
        if (state.isSearchMode) {
          return FeedResultsSliver<RecommendItem>(
            items: state.items,
            coverOf: (item) => item.cover,
            titleOf: (item) => item.title,
            metaOf: (item) => item.searchMeta,
            introOf: (item) => item.intro,
            onTap: _openDetail,
          );
        }
        final metrics = FeedGridMetrics.of(context);
        return FeedGrid<RecommendItem>(
          items: state.items,
          metrics: metrics,
          itemBuilder: (context, item, width) {
            void onTap() => _openDetail(item);
            // 小说与短剧/漫剧的卡片元信息不同（作者 vs 集数），复用各自
            // 现有卡片，保证封面比例/字号完全一致。
            final novel = item.novel;
            if (novel != null) {
              return NovelGridCard(
                key: ValueKey(item.id),
                item: novel,
                width: width,
                onTap: onTap,
              );
            }
            return VideoCard(
              key: ValueKey(item.id),
              item: item.video!,
              width: width,
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}
