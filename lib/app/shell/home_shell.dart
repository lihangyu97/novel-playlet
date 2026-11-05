import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/mine/mine_page.dart';
import '../../features/mine/mine_providers.dart';
import '../../features/recommend/recommend_page.dart';

/// 两 tab 外壳：推荐 / 我的。
///
/// 小说、短剧、漫剧已经合并成「推荐」页里的分类 tabs，底部只保留推荐与我的。
/// 用 [IndexedStack] 保留各 tab 的滚动位置与已加载数据；后续加 tab 只需在
/// [destinations] 与 [pages] 各加一项。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: '推荐',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: '我的',
    ),
  ];

  static const _pages = <Widget>[RecommendPage(), MinePage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) {
          // IndexedStack 的页面不会因切 tab 重建，缓存数字会停在进 App 那一刻；
          // 切到「我的」时重算一次（视频缓存只有播放时才变）。
          if (value == 1) ref.invalidate(cacheUsageProvider);
          setState(() => _index = value);
        },
        destinations: _destinations,
      ),
    );
  }
}
