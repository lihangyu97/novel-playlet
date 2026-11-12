import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/category_tab_bar.dart';
import '../../app/widgets/top_glow.dart';
import 'mine_drama_providers.dart';
import 'mine_providers.dart';
import 'widgets/mine_drama_tab.dart';
import 'widgets/mine_header.dart';
import 'widgets/mine_novel_tab.dart';

/// 我的页的两个 tab：小说 / 短剧。
enum _MineTab {
  novel('小说'),
  drama('短剧');

  const _MineTab(this.label);

  final String label;
}

/// 我的：统一页头 + 小说 / 短剧两个 tab。
///
/// 页头（图标 + 「我的」 + 合并统计 + 设置）与分类 tabs 固定贴顶、不随内容
/// 滚动；两个 tab 各自一条独立的 [CustomScrollView]（[TabBarView] 保活），
/// 点击 tab 或左右滑动都能切换。顶部氛围渐变整页共用一套，不随 tab 变化。
///
/// 两个 tab 的内容完全隔离：小说侧 = 书架 + 最近阅读；短剧侧 = 收藏 +
/// 最近观看（点击直接续播对应集）。两边共用 [MineTabBody] 骨架与页头，
/// 只有数据与内容注入不同。
///
/// 页面根节点**不订阅任何数据 provider**（页头统计由 [_MineStats] 叶子自己
/// watch）：阅读页每 400ms 落一次进度，如果根节点 watch 数据，保活的整页都会
/// 跟着重建（CODE_REVIEW P1-5）。tab 内容同理，书架/收藏与最近阅读/观看各自
/// 订阅自己的通道。
class MinePage extends StatefulWidget {
  const MinePage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表末尾多留这么多空白。
  final double bottomInset;

  /// 测试/无障碍定位用（两个 tab 各自的内容页）。
  static const novelTabKey = Key('mine-tab-novel');
  static const dramaTabKey = Key('mine-tab-drama');

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage>
    with SingleTickerProviderStateMixin {
  static const _tabs = _MineTab.values;

  late final TabController _tabController = TabController(
    length: _tabs.length,
    vsync: this,
    // 比默认 300ms 略快：点 tab 时页面和 tab 高亮都更快到位。
    animationDuration: const Duration(milliseconds: 220),
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _openSettings() {
    context.pushAppRoute(const SettingsRoute());
  }

  @override
  Widget build(BuildContext context) {
    // 渐变要盖到状态栏那一条（安全区不参与布局），否则顶部会留一条纯白。
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          // 顶部固定模块（页头 + tabs）的氛围渐变：整页一套，不随 tab 切换。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 150 + topInset,
            child: const TopGlow(spec: kMineTopGlow),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                MineHeader(
                  title: '我的',
                  icon: Icons.person_rounded,
                  stats: const _MineStats(),
                  onSettings: _openSettings,
                ),
                CategoryTabBar(
                  controller: _tabController,
                  labels: [for (final tab in _tabs) tab.label],
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _KeepAliveTab(
                        key: MinePage.novelTabKey,
                        child: MineNovelTab(bottomInset: widget.bottomInset),
                      ),
                      _KeepAliveTab(
                        key: MinePage.dramaTabKey,
                        child: MineDramaTab(bottomInset: widget.bottomInset),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 页头统计行：只订阅「书架本数 / 收藏部数」。
///
/// 单独做成 ConsumerWidget，[MinePage] 根节点自己不 watch 任何数据 provider：
/// 阅读进度落盘（最近阅读变化）与这两个计数无关，页面根节点与固定页头不该
/// 因此整页重建（CODE_REVIEW P1-5）。这里也顺手预取了还没进过的 tab 数据。
class _MineStats extends ConsumerWidget {
  const _MineStats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(mineShelfProvider);
    final collections = ref.watch(mineDramaShelfProvider);
    final shelfCount = shelf.value?.length;
    final collectionCount = collections.value?.length;
    final String text;
    if (shelfCount != null && collectionCount != null) {
      text = '书架 $shelfCount 本 · 收藏 $collectionCount 部';
    } else if (shelf.hasError || collections.hasError) {
      text = '本地数据暂时读不出来';
    } else {
      text = '正在读取本地数据…';
    }
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// [TabBarView] 的保活壳：tab 滑走不销毁内容，滚动位置与已加载数据都保留
/// （与推荐页的分类页同一套做法）。
class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({super.key, required this.child});

  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
