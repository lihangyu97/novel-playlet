import 'package:flutter/material.dart';

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
