import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/widgets/states.dart';
import '../../data/models/json_utils.dart' show isRetryableError;
import '../../data/models/rank.dart';
import '../feed/feed_state.dart';
import '../feed/feed_view.dart';
import 'rank_entry_route.dart';
import 'rank_providers.dart';
import 'widgets/rank_entry_row.dart';

/// 榜单目录加载器（测试可注入）。
typedef RankCatalogLoader = Future<RankCatalog> Function();

/// 一页榜单加载器（测试可注入）。
typedef RankPageLoader = Future<RankBoard> Function({
  required String rankId,
  required RankTab tab,
  required int offset,
  required int startAt,
});

/// 排行榜页：二级 tab（推荐榜 / 完本榜 / 巅峰榜 / 新书榜 / 短剧榜 / 漫剧榜）+
/// 名次列表。
///
/// 与首页一样用 [TabController] + [TabBarView]：内容区可以左右滑切榜，每个
/// tab 的列表由 [_RankTabPage] 自己持有并 keep-alive，切走再回来不重新请求，
/// 滚动位置也保留。从首页榜单卡片的「更多」进入时带 [initialAlgo] 自动定位。
class RankPage extends ConsumerStatefulWidget {
  const RankPage({
    super.key,
    this.initialAlgo,
    this.catalogLoader,
    this.pageLoader,
  });

  /// 从首页卡片进来时选中的榜（`rank_algo`）。
  final int? initialAlgo;

  final RankCatalogLoader? catalogLoader;
  final RankPageLoader? pageLoader;

  @override
  ConsumerState<RankPage> createState() => _RankPageState();
}

class _RankPageState extends ConsumerState<RankPage>
    with TickerProviderStateMixin {
  RankCatalog _catalog = RankCatalog.empty;
  List<RankTab> _tabs = const [];
  TabController? _tabController;

  bool _loadingCatalog = true;
  String? _catalogError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<RankCatalog> _loadCatalog() {
    final loader = widget.catalogLoader;
    if (loader != null) return loader();
    // 首页卡片已经拉过目录时直接复用；失败/空目录时由重试入口 invalidate。
    return ref.read(rankCatalogProvider.future);
  }

  void _retryCatalog() {
    ref.invalidate(rankCatalogProvider);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    final oldController = _tabController;
    _tabController = null;
    oldController?.dispose();
    setState(() {
      _loadingCatalog = true;
      _catalogError = null;
    });

    RankCatalog catalog;
    try {
      catalog = await _loadCatalog();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingCatalog = false;
        _catalogError = describeFeedError(error);
      });
      return;
    }
    if (!mounted || generation != _generation) return;
    if (catalog.isEmpty) {
      setState(() {
        _loadingCatalog = false;
        _catalogError = '排行榜暂时不可用';
      });
      return;
    }

    final tabs = _orderTabs(catalog.tabs);
    final initialAlgo = widget.initialAlgo;
    var index = initialAlgo == null
        ? 0
        : tabs.indexWhere((tab) => tab.algo == initialAlgo);
    if (index < 0) index = 0;
    final controller = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: index,
    );

    setState(() {
      _catalog = catalog;
      _tabs = tabs;
      _tabController = controller;
      _loadingCatalog = false;
      _catalogError = null;
    });
  }

  /// 小说榜在前，短剧榜次之，漫剧榜最后；同组内保持上游目录顺序。
  static List<RankTab> _orderTabs(List<RankTab> tabs) {
    int group(RankTab tab) {
      if (tab.genreTab == 2) return 0;
      if (tab.genreTab == 4) return 1;
      if (tab.genreTab == 5) return 2;
      return 3;
    }

    final indexed = tabs.indexed.toList();
    indexed.sort((a, b) {
      final byGroup = group(a.$2).compareTo(group(b.$2));
      return byGroup != 0 ? byGroup : a.$1.compareTo(b.$1);
    });
    return [for (final item in indexed) item.$2];
  }

  @override
  Widget build(BuildContext context) {
    final controller = _tabController;
    return Scaffold(
      appBar: AppBar(title: const Text('排行榜')),
      body: _loadingCatalog
          ? const LoadingView(label: '正在加载榜单…')
          : _catalogError != null
          ? ErrorView(message: _catalogError!, onRetry: _retryCatalog)
          : controller == null || _tabs.isEmpty
          ? const LoadingView(label: '正在加载榜单…')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _RankTabBar(controller: controller, tabs: _tabs),
                Expanded(
                  child: TabBarView(
                    key: const Key('rank_pages'),
                    controller: controller,
                    children: [
                      for (final tab in _tabs)
                        _RankTabPage(
                          key: PageStorageKey<String>('rank-tab-${tab.algo}'),
                          rankId: _catalog.rankId,
                          tab: tab,
                          pageLoader: widget.pageLoader,
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// 单个榜的内容页：自己请求、分页、保持状态。
///
/// keep-alive 是「已请求 tab 不重复拉」的关键：TabBarView 滑走只把页面移出
/// 视口，不会销毁；切回来时沿用原来的 entries 和 ScrollController。
class _RankTabPage extends ConsumerStatefulWidget {
  const _RankTabPage({
    super.key,
    required this.rankId,
    required this.tab,
    this.pageLoader,
  });

  final String rankId;
  final RankTab tab;
  final RankPageLoader? pageLoader;

  @override
  ConsumerState<_RankTabPage> createState() => _RankTabPageState();
}

class _RankTabPageState extends ConsumerState<_RankTabPage>
    with AutomaticKeepAliveClientMixin {
  /// 列表状态复用首页流那一套：加载更多/翻页失败/是否还有下一页都由它描述。
  FeedState<RankEntry> _state = const FeedState<RankEntry>(items: []);

  final _scrollController = ScrollController();

  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<RankBoard> _loadBoard({required int offset, required int startAt}) {
    final loader = widget.pageLoader;
    if (loader != null) {
      return loader(
        rankId: widget.rankId,
        tab: widget.tab,
        offset: offset,
        startAt: startAt,
      );
    }
    return ref
        .read(apiClientProvider)
        .rankBoard(
          rankId: widget.rankId,
          algo: widget.tab.algo,
          genreTab: widget.tab.genreTab,
          offset: offset,
          startAt: startAt,
        );
  }

  /// 榜单接口的「还有没有下一页」：`has_more` 为准，游标缺失时按本页条数兜底。
  int? _nextOffsetOf(RankBoard board) {
    if (!board.hasMore) return null;
    return board.nextOffset ?? board.entries.length;
  }

  Future<void> _loadFirst() async {
    final token = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _state = const FeedState<RankEntry>(items: []);
    });
    try {
      final board = await _loadBoard(offset: 0, startAt: 1);
      if (!mounted || token != _generation) return;
      setState(() {
        _state = FeedState<RankEntry>(
          items: board.entries,
          nextOffset: _nextOffsetOf(board),
        );
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _error = describeFeedError(error);
      });
    }
  }

  /// 触底/重试都走这里；并发守卫与「到底了不再发」由 [_state] 决定。
  Future<void> _loadMore() async {
    if (_loading || _state.loadingMore || !_state.hasMore) return;
    if (!_state.loadMoreRetryable) return;
    final token = _generation;
    final offset = _state.nextOffset;
    if (offset == null) return;
    setState(
      () => _state = _state.withLoadingMore(true).withLoadMoreError(null),
    );
    try {
      final board = await _loadBoard(
        offset: offset,
        startAt: _state.items.length + 1,
      );
      if (!mounted || token != _generation) return;
      setState(() {
        _state = _state
            .appendPage(
              newItems: board.entries,
              idOf: (entry) => entry.id,
              nextOffset: _nextOffsetOf(board),
            )
            .withLoadingMore(false)
            .withLoadMoreError(null);
      });
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _state = _state
            .withLoadingMore(false)
            .withLoadMoreError(
              describeFeedError(error),
              retryable: isRetryableError(error),
            );
      });
    }
  }

  void _openEntry(RankEntry entry) {
    openRankEntry(context, entry, source: 'rank-${widget.tab.algo}');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const LoadingView(label: '正在加载榜单…');
    }
    if (_error != null && _state.items.isEmpty) {
      return ErrorView(message: _error!, onRetry: _loadFirst);
    }
    return FeedView<RankEntry>(
      state: _state,
      controller: _scrollController,
      onRefresh: _loadFirst,
      onLoadMore: _loadMore,
      onRetryLoadMore: _loadMore,
      emptyMessage: '该榜单暂无内容',
      emptyIcon: Icons.leaderboard_outlined,
      sliverBuilder: (context, state) => SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final entry = state.items[index];
          return RankEntryRow(
            entry: entry,
            source: 'rank-${widget.tab.algo}',
            onTap: () => _openEntry(entry),
          );
        }, childCount: state.items.length),
      ),
    );
  }
}

/// 横滑的二级 tab：文字 tab（无下划线），选中态用主题色 + 加粗。
class _RankTabBar extends StatelessWidget {
  const _RankTabBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<RankTab> tabs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final selectedIndex = controller.index.clamp(0, tabs.length - 1);
        return SizedBox(
          height: 44,
          child: ListView.separated(
            key: const Key('rank_tabs'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: tabs.length,
            separatorBuilder: (context, index) => const SizedBox(width: 18),
            itemBuilder: (context, index) {
              final tab = tabs[index];
              final selected = index == selectedIndex;
              return InkWell(
                key: ValueKey('rank_tab_${tab.algo}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => controller.animateTo(index),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  child: Center(
                    child: Text(
                      tab.name,
                      maxLines: 1,
                      style: TextStyle(
                        color: selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontSize: 13.5,
                        height: 1.2,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
