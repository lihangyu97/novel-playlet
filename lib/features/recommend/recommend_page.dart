import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feed/feed_results.dart';
import '../feed/feed_search_field.dart';
import '../feed/feed_staggered_grid.dart';
import '../feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../app/widgets/top_glow.dart';
import '../video/widgets/video_card.dart';
import 'recommend_category.dart';
import 'recommend_controller.dart';
import 'recommend_item.dart';
import 'recommend_layout.dart';
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
  ConsumerState<RecommendPage> createState() => RecommendPageState();
}

/// 推荐页 State：对壳层暴露 [scrollActiveFeedToTop]，供底栏「再次点击推荐」
/// 时把当前分类的列表平滑滚回顶部。
class RecommendPageState extends ConsumerState<RecommendPage>
    with SingleTickerProviderStateMixin {
  static const _categories = RecommendCategory.values;

  late final TabController _tabController = TabController(
    length: _categories.length,
    vsync: this,
  );
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// 每个分类一条列表滚动控制器：分类页保活，滚动位置各自独立；
  /// 底栏再次点「推荐」时只滚当前分类这一条。
  final _feedControllers = <RecommendCategory, ScrollController>{};

  ScrollController _feedControllerFor(RecommendCategory category) =>
      _feedControllers.putIfAbsent(category, ScrollController.new);

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
    for (final controller in _feedControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 当前分类的列表平滑滚回顶部。
  ///
  /// 由壳层在「已经处于推荐 tab 时再次点击推荐」时调用；已经在顶部就是无操作，
  /// 不会白跑一次动画。别的分类保活着，位置不动。
  void scrollActiveFeedToTop() {
    final controller = _feedControllers[_activeCategory];
    if (controller == null ||
        !controller.hasClients ||
        controller.offset <= 0) {
      return;
    }
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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

  void _openCacheCenter() {
    context.pushAppRoute(const CacheCenterRoute());
  }

  @override
  Widget build(BuildContext context) {
    final activeQuery = ref.watch(searchQueryProvider);

    // 渐变要盖到状态栏那一条（安全区不参与布局），否则顶部会留一条纯白。
    final topInset = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        // 顶部固定模块（搜索框 + 分类 tabs）的蓝粉氛围渐变：固定不滚动。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 116 + topInset,
          child: const TopGlow(spec: kRecommendTopGlow),
        ),
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 搜索框常驻顶部，不随列表滚动收起；右侧固定「已缓存」入口。
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
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
                    const SizedBox(width: 8),
                    _CachedEntryButton(onTap: _openCacheCenter),
                  ],
                ),
              ),
              // tabs 与列表之间留呼吸空间。
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildCategoryTabs(context),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    for (final category in _categories)
                      _CategoryFeedPage(
                        key: ValueKey(category),
                        category: category,
                        bottomInset: widget.bottomInset,
                        scrollController: _feedControllerFor(category),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
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
    required this.scrollController,
  });

  final RecommendCategory category;
  final double bottomInset;

  /// 分类级滚动控制器（推荐页持有，用于底栏再次点击时回顶）。
  final ScrollController scrollController;

  @override
  ConsumerState<_CategoryFeedPage> createState() => _CategoryFeedPageState();
}

class _CategoryFeedPageState extends ConsumerState<_CategoryFeedPage>
    with AutomaticKeepAliveClientMixin {
  RecommendCategory get _category => widget.category;

  /// 当前分类的封面原生比例：小说 3:4，短剧/漫剧 7:10。
  double get _coverAspect => _category == RecommendCategory.novel
      ? kNovelCoverAspect
      : kVideoCoverAspect;

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
    // 布局偏好在这里 watch（不要放进 sliverBuilder 闭包里）：切换双列/三列
    // 时整页重建，瀑布流按新列数重新排版。
    final layout = ref.watch(recommendLayoutProvider);
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
      controller: widget.scrollController,
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
            coverAspect: _coverAspect,
            coverOf: (item) => item.cover,
            titleOf: (item) => item.title,
            metaOf: (item) => item.searchMeta,
            introOf: (item) => item.intro,
            onTap: _openDetail,
            heroTagOf: _coverHeroTag,
          );
        }
        return FeedStaggeredGrid<RecommendItem>(
          items: state.items,
          columns: layout.columns,
          itemBuilder: (context, item, width) {
            void onTap() => _openDetail(item);
            final heroTag = _coverHeroTag(item);
            // 小说与短剧/漫剧的卡片元信息不同（作者 vs 集数），复用各自
            // 现有卡片；推荐流统一是白底不定高卡片，封面按内容域原生比例。
            return switch (item) {
              NovelRecommendItem(:final novel) => NovelGridCard(
                key: ValueKey(item.id),
                item: novel,
                width: width,
                onTap: onTap,
                heroTag: heroTag,
                // 推荐流：作者固定一行；双列时理由上封面角标、热度右对齐，
                // 三列放不下就退回理由/热度各自一行。
                showRecommendMeta: true,
                reasonOnCover: layout.columns == 2,
                surface: true,
                naturalTitleHeight: true,
                coverAspect: kNovelCoverAspect,
              ),
              VideoRecommendItem(:final video) => VideoCard(
                key: ValueKey(item.id),
                item: video,
                width: width,
                onTap: onTap,
                heroTag: heroTag,
                // 短剧/漫剧同规则：集数固定一行；双列理由上封面、热度右对齐。
                showRecommendMeta: true,
                reasonOnCover: layout.columns == 2,
                surface: true,
                naturalTitleHeight: true,
                coverAspect: kVideoCoverAspect,
              ),
            };
          },
        );
      },
    );
  }
}

/// 搜索框右侧的「已缓存」入口：跳转缓存中心（离线下载的书 / 短剧）。
///
/// 与搜索框同高、同底色、同圆角（[FeedSearchField.radius]），只放文字，把
/// 视觉重心留给输入框；高度 40 满足触控下限。
class _CachedEntryButton extends StatelessWidget {
  const _CachedEntryButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(FeedSearchField.radius);
    return Tooltip(
      message: '已缓存',
      child: Semantics(
        button: true,
        label: '已缓存',
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: SizedBox(
              height: FeedSearchField.height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    '已缓存',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
