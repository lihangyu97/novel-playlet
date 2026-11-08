import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feed/feed_grid.dart';
import '../feed/feed_results.dart';
import '../feed/feed_search_field.dart';
import '../feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
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
  const RecommendPage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表底部多留这么多空白，
  /// 最后一屏才能滚到胶囊上方。直接作为页面根节点时保持 0。
  final double bottomInset;

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

  /// 折叠判定阈值（方向 + 位移）：
  /// - 向下滚够 [_collapseTravel] 且已离开顶部 [_collapseAt] 才收起，避免一点就收；
  /// - 向上滚 [_revealTravel] 立即展开：滚很深时，用户往回滑的第一下就该看到
  ///   搜索框，而不是等一路滚回顶部。
  static const double _collapseTravel = 28;
  static const double _revealTravel = 6;
  static const double _collapseAt = 48;
  static const double _expandAt = 8;

  /// 顶部搜索框是否已收起（只为列表腾空间，搜索态永远展开）。
  bool _searchCollapsed = false;

  /// 上一次滚动位置；切分类时置空，避免把「新列表从 0 开始」误读成一次
  /// 巨大的向上滚动而把搜索框弹出来。
  double? _lastPixels;

  /// 当前方向累计的滚动距离（方向一变就清零）。
  double _downTravel = 0;
  double _upTravel = 0;

  RecommendCategory get _activeCategory => _categories[_tabController.index];

  @override
  void initState() {
    super.initState();
    // 页面可能因切 tab 重建，但 provider 里的关键词还在：回填输入框，
    // 否则会看到"结果列表 + 空搜索框"的错位状态。
    final query = ref.read(searchQueryProvider);
    if (query != null) _searchController.text = query;
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
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

  /// 折叠状态是页面级的：收起后左右切分类保持收起，不因为新分类在顶部
  /// 就把搜索框弹回来。这里只清掉方向累计，避免新列表的第一次通知被当成
  /// 跨列表的巨大位移。
  void _onTabChanged() {
    _lastPixels = null;
    _downTravel = 0;
    _upTravel = 0;
  }

  /// 竖向列表的滚动通知会冒泡到这里；PageView 的横向滚动按 axis 过滤掉。
  ///
  /// 搜索态不参与折叠：搜索结果与推荐流是两条列表，用搜索结果的滚动位置
  /// 影响折叠会让「取消搜索后回到推荐流」的状态错乱。
  bool _handleScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (ref.read(searchQueryProvider) != null) return false;
    final offset = notification.metrics.pixels;
    final last = _lastPixels;
    _lastPixels = offset;
    if (last == null) return false;
    final delta = offset - last;
    if (delta > 0) {
      _downTravel += delta;
      _upTravel = 0;
    } else if (delta < 0) {
      _upTravel += -delta;
      _downTravel = 0;
    }
    _updateCollapsed(offset);
    return false;
  }

  /// 收起/展开判定。
  ///
  /// 搜索态或输入框聚焦时永远展开：正在输入/看搜索结果时把输入框藏起来
  /// 会让人不知道自己在哪、也没法改关键词。
  void _updateCollapsed(double offset) {
    if (!mounted) return;
    final bool next;
    if (ref.read(searchQueryProvider) != null || _searchFocus.hasFocus) {
      next = false;
    } else if (_searchCollapsed) {
      // 回到顶部附近，或任意一次向上的滚动（不看滚了多深）都立即展开。
      final atTop = offset <= _expandAt;
      final scrollingBack = _upTravel >= _revealTravel;
      next = !(atTop || scrollingBack);
    } else {
      next = offset > _collapseAt && _downTravel >= _collapseTravel;
    }
    _applyCollapsed(next);
  }

  void _applyCollapsed(bool next) {
    if (next == _searchCollapsed) return;
    setState(() => _searchCollapsed = next);
    _downTravel = 0;
    _upTravel = 0;
  }

  @override
  Widget build(BuildContext context) {
    final activeQuery = ref.watch(searchQueryProvider);
    // 进入搜索态立即展开输入框；退出搜索时保持当前状态（推荐流的滚动位置
    // 没变，不需要再按偏移重新判断）。
    ref.listen(searchQueryProvider, (previous, next) {
      if (next != null) _applyCollapsed(false);
    });

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 搜索框常驻但可收起：上滑浏览时整条折叠，把屏幕让给列表；
          // 回到顶部或进入搜索态自动展开。AnimatedSize 让高度变化是动画，
          // 列表跟随变高、滚动偏移不变，不会出现跳帧感。
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _searchCollapsed
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    // 提示文案跟着当前分类走；AnimatedBuilder 同时让左右滑动
                    // 切分类时提示词及时更新。
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
          ),
          // tabs 与列表之间留呼吸空间；收起搜索框时给 tabs 补回状态栏下方的
          // 安全距离，否则下划线会贴着状态栏。
          Padding(
            padding: EdgeInsets.only(top: _searchCollapsed ? 8 : 0, bottom: 8),
            child: _buildCategoryTabs(context),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScroll,
              child: TabBarView(
                controller: _tabController,
                children: [
                  for (final category in _categories)
                    _CategoryFeedPage(
                      key: ValueKey(category),
                      category: category,
                      bottomInset: widget.bottomInset,
                    ),
                ],
              ),
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
      // 高度从 M3 默认的 46 收到 36：分类只有两三个字，46pt 会让顶部显得很厚。
      padding: const EdgeInsets.symmetric(horizontal: 6),
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(width: 2.5, color: scheme.primary),
        insets: const EdgeInsets.symmetric(horizontal: 4),
      ),
      dividerColor: Colors.transparent,
      tabs: [
        for (final category in _categories)
          Tab(height: 36, text: category.label),
      ],
    );
  }
}

/// 单个分类的流（推荐/搜索共用）。
///
/// 用 [AutomaticKeepAliveClientMixin] 保活：TabBarView 滚出屏幕后会销毁子树，
/// 保活才能让每个分类的滚动位置在左右滑动切回时原样保留。
class _CategoryFeedPage extends ConsumerStatefulWidget {
  const _CategoryFeedPage({
    super.key,
    required this.category,
    required this.bottomInset,
  });

  final RecommendCategory category;
  final double bottomInset;

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeFeedError(error))));
    }
  }

  void _retry() => ref.invalidate(recommendFeedProvider(_category));

  void _retryLoadMore() => _controller.retryLoadMore();

  /// 列表封面 Hero tag：分类名进 tag，同一路由里被 TabBarView 保活的多个
  /// 分类互不冲突；详情页用同一个 tag 接住飞入动画。
  String _coverHeroTag(RecommendItem item) {
    final source = 'recommend-${_category.name}';
    return switch (item) {
      NovelRecommendItem() => CoverHeroTag.novel(source, item.id),
      VideoRecommendItem() => CoverHeroTag.video(source, item.id),
    };
  }

  void _openDetail(RecommendItem item) {
    final heroTag = _coverHeroTag(item);
    switch (item) {
      case NovelRecommendItem(:final novel):
        context.pushAppRoute(
          DetailRoute(bookId: novel.id, preview: novel, heroTag: heroTag),
        );
      case VideoRecommendItem(:final video):
        context.pushAppRoute(
          VideoDetailRoute(
            seriesId: video.id,
            preview: video,
            heroTag: heroTag,
          ),
        );
    }
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
      bottomInset: widget.bottomInset,
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
            heroTagOf: _coverHeroTag,
          );
        }
        final metrics = FeedGridMetrics.of(context);
        return FeedGrid<RecommendItem>(
          items: state.items,
          metrics: metrics,
          itemBuilder: (context, item, width) {
            void onTap() => _openDetail(item);
            final heroTag = _coverHeroTag(item);
            // 小说与短剧/漫剧的卡片元信息不同（作者 vs 集数），复用各自
            // 现有卡片，保证封面比例/字号完全一致。
            return switch (item) {
              NovelRecommendItem(:final novel) => NovelGridCard(
                key: ValueKey(item.id),
                item: novel,
                width: width,
                onTap: onTap,
                heroTag: heroTag,
                // 推荐流展示「作者 · 评分」；书架等入口不传，保持原元信息。
                showScore: true,
              ),
              VideoRecommendItem(:final video) => VideoCard(
                key: ValueKey(item.id),
                item: video,
                width: width,
                onTap: onTap,
                heroTag: heroTag,
              ),
            };
          },
        );
      },
    );
  }
}
