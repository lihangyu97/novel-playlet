import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/mine/mine_page.dart';
import '../../features/recommend/recommend_page.dart';
import 'floating_navigation_bar.dart';

/// 两 tab 外壳：推荐 / 我的。
///
/// 小说、短剧、漫剧已经合并成「推荐」页里的分类 tabs，底部只保留推荐与我的。
/// 页面用 [PageView] 承载：点底栏时横向滑动切换（PiliPlus 同款），而不是
/// 硬切；`NeverScrollableScrollPhysics` 关掉手势翻页，避免和推荐页里的
/// 分类 tabs 左右滑动手势打架。页面子树用 keep-alive 保活，保留滚动位置与
/// 已加载数据。
///
/// 底栏项与页面由同一张 [_tabs] 表驱动（顺序即 tab 顺序）：加一个 tab 只改
/// 这张表，不用再同步维护 destinations 和 PageView children 两份列表。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  final _pageController = PageController();

  /// 拿到推荐页 State：底栏「推荐」处于选中态时再次点击，要把当前分类的
  /// 列表平滑滚回顶部（页面用 keep-alive 保活，滚动位置在页面子树里）。
  final _recommendKey = GlobalKey<RecommendPageState>();

  static const _slideDuration = Duration(milliseconds: 280);

  /// 每个 tab = 一条底栏项 + 一个页面构造器（页面需要底栏高度留白）。
  ///
  /// 不是 const：页面构造器是闭包（还要捕获 [_recommendKey]），但这个列表
  /// 只在 State 里建一次。
  late final _tabs = <_ShellTab>[
    _ShellTab(
      destination: const FloatingNavigationDestination(
        icon: Icon(Icons.explore_outlined),
        selectedIcon: Icon(Icons.explore),
        label: '推荐',
      ),
      builder: (bottomInset) =>
          RecommendPage(key: _recommendKey, bottomInset: bottomInset),
    ),
    _ShellTab(
      destination: const FloatingNavigationDestination(
        icon: Icon(Icons.person_outline),
        selectedIcon: Icon(Icons.person),
        label: '我的',
      ),
      builder: (bottomInset) => MinePage(bottomInset: bottomInset),
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onDestinationSelected(int value) {
    if (value == _index) {
      // 已经在该 tab：推荐页再次点击 = 当前分类列表平滑回顶（常见交互）。
      // 「我的」等其它 tab 暂不需要，保持无操作。
      if (value == 0) _recommendKey.currentState?.scrollActiveFeedToTop();
      return;
    }
    // 底栏高亮先跟着点击走，页面再滑过去，避免滑动期间选中态滞后。
    setState(() => _index = value);
    _pageController.animateToPage(
      value,
      duration: _slideDuration,
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 内容从悬浮胶囊下面穿过；各页面列表末尾留出这段高度，最后一行不会被
    // 胶囊永久遮住。
    final bottomInset = FloatingNavigationBar.totalHeight(context);
    return Scaffold(
      // extendBody：body 一直铺到屏幕底部，胶囊浮在内容上面（PiliPlus 同款）。
      // 底栏槽位用 Center(heightFactor: 1) 让胶囊按自身宽度居中、槽位高度
      // 收缩到胶囊高度。
      extendBody: true,
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final tab in _tabs)
            _KeepAlivePage(child: tab.builder(bottomInset)),
        ],
      ),
      bottomNavigationBar: Center(
        heightFactor: 1,
        child: FloatingNavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onDestinationSelected,
          backgroundColor: scheme.surface,
          indicatorColor: scheme.primary.withValues(alpha: 0.14),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            return TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            );
          }),
          destinations: [for (final tab in _tabs) tab.destination],
        ),
      ),
    );
  }
}

/// 一个底部 tab：底栏项 + 页面构造器。
class _ShellTab {
  const _ShellTab({required this.destination, required this.builder});

  final FloatingNavigationDestination destination;
  final Widget Function(double bottomInset) builder;
}

/// 让 [PageView] 离屏的页面保持存活（滚动位置、搜索框内容、已加载列表都
/// 在子树 State 里，销毁后回来会重置）。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
