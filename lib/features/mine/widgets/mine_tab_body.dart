import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_section_header.dart';
import '../../../app/widgets/states.dart';

/// 我的页单个 tab 的内容骨架：可滚动的「最近块 + 网格块」+ 底部留白。
///
/// 页头与小说/短剧 tabs 由页面固定贴在顶部（见 `MinePage`），这里只负责
/// 当前 tab 的内容；两个 tab 各自一条 [CustomScrollView]，滚动位置互不影响。
///
/// 小说 / 短剧两侧的骨架完全一样，差异全部通过参数注入：最近块、网格块、
/// 加载/错误占位。[recent] 与 [grid] 都是**已经订阅好自己数据**的 widget：
/// 最近阅读只依赖进度通道，网格只依赖书架通道，阅读进度写入时只有最近块重建
/// （CODE_REVIEW P1-5）。
class MineTabBody extends StatelessWidget {
  const MineTabBody({
    super.key,
    required this.bottomInset,
    required this.placeholder,
    this.recent,
    this.grid,
  });

  /// 悬浮底栏遮住的高度；列表末尾多留这么多空白。
  final double bottomInset;

  /// 数据未就绪时的占位（加载中 / 读取失败）。
  final Widget placeholder;

  /// 最近阅读/观看整块；null = 这一块不渲染（例如没有阅读记录）。
  final Widget? recent;

  /// 书架/收藏整块（区块标题 + 网格）；null = 数据未就绪，只渲染 [placeholder]。
  final Widget? grid;

  @override
  Widget build(BuildContext context) {
    final grid = this.grid;
    final recent = this.recent;
    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        if (grid != null) ...[
          if (recent != null) SliverToBoxAdapter(child: recent),
          SliverToBoxAdapter(child: grid),
        ] else
          // 数据没就绪时占位区沿用原来的 220 高度，避免骨架高度跳一下。
          SliverToBoxAdapter(child: SizedBox(height: 220, child: placeholder)),
        // 存储/清缓存入口在「设置」页；这里只留书架与最近阅读/观看。
        SliverToBoxAdapter(child: SizedBox(height: 28 + bottomInset)),
      ],
    );
  }
}

/// 「最近块 + 区块标题 + 网格」的标准装配：我的页小说/短剧两个 tab 共用。
///
/// 两个 tab 只差数据源、文案与网格组件；加载/失败占位、区块标题的留白、
/// 数据未就绪时不渲染标题这些规则都收在这里，避免两边再各写一遍、慢慢漂移。
Widget mineTabSection<T>({
  required double bottomInset,
  required AsyncValue<List<T>> async,
  required String errorMessage,
  required String loadingLabel,
  required VoidCallback onRetry,
  required String title,
  String? hint,
  required Widget Function(List<T> items) gridBuilder,
  required Widget recent,
}) {
  final items = async.value;
  return MineTabBody(
    bottomInset: bottomInset,
    placeholder: async.hasError
        ? ErrorView(message: errorMessage, onRetry: onRetry)
        : LoadingView(label: loadingLabel),
    recent: recent,
    grid: items == null
        ? null
        : Column(
            children: [
              AppSectionHeader(
                title: title,
                hint: hint,
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              ),
              gridBuilder(items),
            ],
          ),
  );
}

/// 「最近阅读 / 最近观看」整块：区块标题 + 列表，没有记录时给同高（140）的
/// 空态提示。两个 tab 共用，空态规则不会再一个隐藏、一个留白。
///
/// 不再额外加顶部留白：tabs 的下划线贴行底，区块标题自己的 8pt 上边距就是
/// 「下划线 → 第一个标题」的间距（与页头到 tabs 的 8pt 等宽）。
Widget mineRecentSection({
  required String title,
  required bool isEmpty,
  required String emptyMessage,
  required Widget child,
}) {
  return Column(
    children: [
      AppSectionHeader(
        title: title,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      ),
      if (isEmpty)
        SizedBox(
          height: 140,
          child: EmptyView(message: emptyMessage, icon: Icons.history_rounded),
        )
      else
        child,
    ],
  );
}
