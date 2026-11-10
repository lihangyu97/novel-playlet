import 'package:flutter/material.dart';

/// 我的页单个 tab 的内容骨架：可滚动的「最近块 + 网格块」+ 底部留白。
///
/// 页头与小说/短剧 tabs 由页面固定贴在顶部（见 [MinePage]），这里只负责
/// 当前 tab 的内容；两个 tab 各自一条 [CustomScrollView]，滚动位置互不影响。
///
/// 小说 / 短剧两侧的骨架完全一样，差异全部通过参数注入：数据、最近块、
/// 网格块、加载/错误占位。
class MineTabBody<TData> extends StatelessWidget {
  const MineTabBody({
    super.key,
    required this.data,
    required this.bottomInset,
    required this.placeholder,
    required this.recentOf,
    required this.gridOf,
  });

  /// 本 tab 数据；null = 还在加载 / 读失败，此时只渲染 [placeholder]。
  final TData? data;

  /// 悬浮底栏遮住的高度；列表末尾多留这么多空白。
  final double bottomInset;

  /// 数据未就绪时的占位（加载中 / 读取失败）。
  final Widget placeholder;

  /// 最近阅读/观看整块；返回 null 表示这一块不渲染（例如没有阅读记录）。
  final Widget? Function(TData data) recentOf;

  /// 书架/收藏整块（区块标题 + 网格）。
  final Widget Function(TData data) gridOf;

  @override
  Widget build(BuildContext context) {
    final data = this.data;
    final recent = data == null ? null : recentOf(data);
    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        if (data != null) ...[
          if (recent != null) SliverToBoxAdapter(child: recent),
          SliverToBoxAdapter(child: gridOf(data)),
        ] else
          // 数据没就绪时占位区沿用原来的 220 高度，避免骨架高度跳一下。
          SliverToBoxAdapter(child: SizedBox(height: 220, child: placeholder)),
        // 存储/清缓存入口在「设置」页；这里只留书架与最近阅读/观看。
        SliverToBoxAdapter(child: SizedBox(height: 28 + bottomInset)),
      ],
    );
  }
}
