import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../feed/feed_search_field.dart';
import '../feed/feed_staggered_grid.dart';
import '../feed/feed_view.dart';
import '../../app/router.dart';
import '../../app/widgets/category_tab_bar.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../app/widgets/top_glow.dart';
import '../search/search_cue_hint.dart';
import '../video/widgets/video_card.dart';
import 'recommend_category.dart';
import 'recommend_controller.dart';
import 'recommend_item.dart';
import 'recommend_layout.dart';
import 'recommend_state.dart';

/// 合并后的「推荐」页：顶部搜索入口 + 可左右滑动的分类 tabs + 每个分类一条流。
///
/// 搜索已经拆成独立搜索页（`lib/features/search/`）：顶部搜索框是只读入口，
/// 点一下进搜索页一次搜小说 / 短剧，推荐页本身只有推荐流。分类变成搜索框下方
/// 的一级 tabs，各自保留自己的列表、游标与滚动位置；分类 tabs 与内容都支持
/// 左右滑动（tabs 用与我页共用的 [CategoryTabBar]，内容用 `TabBarView`）。
///
/// 页面只保留 tab/滚动控制器这类 UI 状态；列表数据全部在
/// [recommendFeedProvider] 里，切分类不丢已加载的内容。
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
    // 与我的页一致：比默认 300ms 略快，切分类更跟手。
    animationDuration: const Duration(milliseconds: 220),
  );

  /// 搜索框当前轮播到的热词（子组件上报，普通字段，不触发重建）。
  ///
  /// 点进搜索页时带过去，让占位从同一条接着轮播、空输入提交直接搜它。
  String _currentCueWord = '';

  /// 每个分类一条列表滚动控制器：分类页保活，滚动位置各自独立；
  /// 底栏再次点「推荐」时只滚当前分类这一条。
  final _feedControllers = <RecommendCategory, ScrollController>{};

  ScrollController _feedControllerFor(RecommendCategory category) =>
      _feedControllers.putIfAbsent(category, ScrollController.new);

  RecommendCategory get _activeCategory => _categories[_tabController.index];

  @override
  void dispose() {
    _tabController.dispose();
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

  /// 顶部搜索框是只读入口：点一下进独立搜索页，一次搜小说 / 短剧。
  ///
  /// 推荐页本身不再有内联搜索态（旧实现把搜索词塞进三个推荐流 provider），
  /// 返回时推荐流还是原来的内容与滚动位置。
  void _openSearch() =>
      context.pushAppRoute(SearchRoute(initialCueWord: _currentCueWord));

  void _openCacheCenter() {
    context.pushAppRoute(const CacheCenterRoute());
  }

  @override
  Widget build(BuildContext context) {
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
              // 搜索框常驻顶部，不随列表滚动收起；右侧固定下载图标入口。
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      // 只读入口：可点不可编辑，点一下进独立搜索页（一次搜
                      // 小说 / 短剧）。提示词是全局的，不再跟当前分类变。
                      // 语义上它是一个「按钮」而不是只读输入框，读屏才不会被
                      // 当成可编辑控件。
                      child: Semantics(
                        button: true,
                        label: '搜索',
                        excludeSemantics: true,
                        child: FeedSearchField(
                          hintText: '搜索小说 / 短剧',
                          // 热词轮播做占位（placeholder），不写进输入框。
                          hint: SearchCueHint(
                            fallback: '搜索小说 / 短剧',
                            onWordChanged: (word) => _currentCueWord = word,
                          ),
                          readOnly: true,
                          onTap: _openSearch,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _CachedEntryButton(onTap: _openCacheCenter),
                  ],
                ),
              ),
              // tabs 与列表之间留呼吸空间；样式与我的页共用 CategoryTabBar。
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: CategoryTabBar(
                  controller: _tabController,
                  labels: const ['小说', '短剧', '漫剧'],
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
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
}

/// 单个分类的推荐流。
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
    // 布局偏好在这里 watch（不要放进 sliverBuilder 闭包里）：切换双列/三列
    // 时整页重建，瀑布流按新列数重新排版。
    final layout = ref.watch(recommendLayoutProvider);
    final data = async.value;

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

    return FeedView<RecommendItem>(
      state: data,
      bottomInset: widget.bottomInset,
      controller: widget.scrollController,
      onRefresh: _refresh,
      onLoadMore: _controller.loadMore,
      onRetryLoadMore: _retryLoadMore,
      emptyMessage: '暂时没有${_category.label}推荐\n下拉刷新试试',
      emptyIcon: _category.emptyIcon,
      sliverBuilder: (context, state) {
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

/// 搜索框右侧的缓存中心入口：跳转缓存中心（离线下载的书 / 短剧）。
///
/// 只放一个下载图标（`download_outlined`，与详情页「缓存」态同一套图标），
/// 40×40 与搜索框同高、同底色、同圆角（[FeedSearchField.radius]），把视觉
/// 重心留给输入框；文案只走 Tooltip / 无障碍标签，不再占一行文字。
class _CachedEntryButton extends StatelessWidget {
  const _CachedEntryButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(FeedSearchField.radius);
    return Tooltip(
      message: '已缓存',
      child: Semantics(
        button: true,
        label: '已缓存',
        child: Material(
          color: FeedSearchField.surfaceColor(context),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: SizedBox(
              width: FeedSearchField.height,
              height: FeedSearchField.height,
              child: Center(
                child: Icon(
                  Icons.download_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
