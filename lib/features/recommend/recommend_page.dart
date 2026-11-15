import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../feed/feed_search_field.dart';
import '../feed/feed_staggered_grid.dart';
import '../feed/feed_view.dart';
import '../rank/rank_providers.dart';
import '../rank/widgets/rank_preview_card.dart';
import '../../app/router.dart';
import '../../app/widgets/category_tab_bar.dart';
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

/// 合并后的「推荐」页：顶部分类 tabs + 右侧搜索入口 + 每个分类一条流。
///
/// 搜索是独立页面（`lib/features/search/`）：推荐页顶栏不再放整行搜索框，
/// 只留右侧一个放大镜入口（点一下进搜索页，一次搜小说 / 短剧），整体是
/// 小红书式的「分类 tabs + 搜索图标」顶栏。分类 tabs 各自保留自己的列表、
/// 游标与滚动位置；分类 tabs 与内容都支持左右滑动（tabs 用与我页共用的
/// [CategoryTabBar]，内容用 `TabBarView`）。
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

  /// 搜索入口是顶栏右侧的放大镜：点一下进独立搜索页，一次搜小说 / 短剧。
  ///
  /// 推荐页本身不再有内联搜索态（旧实现把搜索词塞进三个推荐流 provider），
  /// 返回时推荐流还是原来的内容与滚动位置。
  void _openSearch() => context.pushAppRoute(const SearchRoute());

  @override
  Widget build(BuildContext context) {
    // 渐变要盖到状态栏那一条（安全区不参与布局），否则顶部会留一条纯白。
    final topInset = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        // 顶部固定模块（分类 tabs + 搜索入口）的蓝粉氛围渐变：固定不滚动。
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
              // 顶栏整行高度按搜索入口（40）定；tabs 行贴行底对齐，下划线
              // 正好落在整行底边上（与搜索入口底边齐平），下面再留 8 给内容。
              // 整行贴住安全区，不再像以前那样先摆一整行搜索框、tabs 只能在
              // 它下面。
              SizedBox(
                height: _SearchEntryButton.size,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 右侧「40 图标 + 8 留白」的镜像占位：tabs 因此落在屏幕
                    // 正中，而不是被右侧搜索入口压到左半边。
                    const SizedBox(width: _SearchEntryButton.size + 8),
                    Expanded(
                      child: CategoryTabBar(
                        controller: _tabController,
                        labels: const ['小说', '短剧', '漫剧'],
                        // 行内左右留白交给外层 Row 的镜像占位，居中才准。
                        padding: EdgeInsets.zero,
                        center: true,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _SearchEntryButton(onTap: _openSearch),
                    ),
                  ],
                ),
              ),
              // tabs 的下划线贴在行底边，这里再留 8：排行榜预览卡 / 首屏卡片
              // 不会贴着下划线，也不会因为榜单卡片收起而改变间距。
              const SizedBox(height: 8),
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

  @override
  void initState() {
    super.initState();
    // 榜单预览和推荐流并行拉：第一次进 tab 时不用等推荐流回来才发榜单请求，
    // 卡片骨架也会更早换成真数据。
    ref.read(rankPreviewProvider(_category));
  }

  RecommendFeedController get _controller =>
      ref.read(recommendFeedProvider(_category).notifier);

  Future<void> _refresh() async {
    try {
      await _controller.refresh();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, describeFeedError(error));
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

  /// 点卡片进详情。
  ///
  /// [cardContext] 是这张卡片自己的 BuildContext（`FeedStaggeredGrid` 的
  /// itemBuilder 给的是整条 sliver 的，算不出卡片在视口里的位置）。
  ///
  /// 把卡片移进可视区的动作放在详情页转场**完全结束之后**：飞行与转场期间
  /// 列表还在详情页下面，用户看不到这次跳动；等详情页完全进来再移，返回时
  /// 落点已经落在视口内。代价是去程 Hero 仍从原位起飞（可能经过底栏），
  /// 这是「转场后再移」这个时序本身的取舍。
  void _openDetail(RecommendItem item, BuildContext cardContext) {
    final heroTag = _coverHeroTag(item);
    final route = switch (item) {
      NovelRecommendItem(:final novel) => DetailRoute(
        bookId: novel.id,
        preview: novel,
        heroTag: heroTag,
      ),
      VideoRecommendItem(:final video) => VideoDetailRoute(
        seriesId: video.id,
        preview: video,
        heroTag: heroTag,
      ),
    }.toRoute();

    pushRouteRevealingHeroSource(
      context,
      route,
      cardContext: cardContext,
      bottomInset: widget.bottomInset,
    );
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
      header: RankPreviewCard(category: _category),
      sliverBuilder: (context, state) {
        return FeedStaggeredGrid<RecommendItem>(
          items: state.items,
          columns: layout.columns,
          itemBuilder: (context, item, width) {
            // 用 [Builder] 拿到「这张卡片自己」的 BuildContext：sliver 的
            // itemBuilder 传进来的是整条 sliver 的 context，算不出卡片在
            // 视口里的位置（见 [revealHeroSource]）。
            return Builder(
              builder: (cardContext) {
                void onTap() => _openDetail(item, cardContext);
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
      },
    );
  }
}

/// 顶栏右侧的搜索入口：40×40 圆角方块 + 一个放大镜，点一下进独立搜索页。
///
/// 小红书式：推荐页不再有整行搜索框，搜索入口收成一个图标按钮，占的正是
/// 以前「已缓存」按钮的位置（同尺寸、同底色、同圆角），文字只走 Tooltip /
/// 无障碍标签。缓存中心入口已经挪到「我的」页头，顶栏只留搜索。
class _SearchEntryButton extends StatelessWidget {
  const _SearchEntryButton({required this.onTap});

  /// 与「我的」页头图标按钮同高，也是本页顶栏的行高。
  static const double size = 40;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(FeedSearchField.radius);
    return Tooltip(
      message: '搜索',
      child: Semantics(
        button: true,
        label: '搜索',
        child: Material(
          color: FeedSearchField.surfaceColor(context),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
