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
/// 已加载数据；后续加 tab 只需在 [destinations] 与 [PageView] 的 children 各加一项。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  final _pageController = PageController();

  static const _slideDuration = Duration(milliseconds: 280);

  static const _destinations = <FloatingNavigationDestination>[
    FloatingNavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: '推荐',
    ),
    FloatingNavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: '我的',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onDestinationSelected(int value) {
    if (value == _index) return;
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
          _KeepAlivePage(child: RecommendPage(bottomInset: bottomInset)),
          _KeepAlivePage(child: MinePage(bottomInset: bottomInset)),
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
          destinations: _destinations,
        ),
      ),
    );
  }
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
