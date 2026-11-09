import 'package:flutter/material.dart';

import 'mine_header.dart';
import 'staggered_block.dart';

/// 我的页单个面板的骨架：固定页头 + 可滚动的「最近块 + 网格块」+ 底部留白。
///
/// 页头（图标 + 主标题 + 副标题）和推荐页的搜索框一样**固定贴顶**、不随列表
/// 滚动；下面两块（最近阅读/观看、书架/收藏）在 [CustomScrollView] 里滚动。
/// 切换面板时页头仍走 100ms 那一拍水平位移，视觉上三块依旧是阶梯错峰。
///
/// 小说/短剧两侧的版式是镜像的，骨架完全一样，差异全部通过参数注入：数据、
/// 标题、统计文案、最近列表、网格、加载/错误占位。短剧侧 [mirrored] = true：
/// 标题/图标靠右，三块也都从右侧滑入。
class PanelShell<TData> extends StatelessWidget {
  const PanelShell({
    super.key,
    required this.data,
    required this.progress,
    required this.mirrored,
    required this.bottomInset,
    required this.title,
    required this.icon,
    required this.stats,
    required this.placeholder,
    required this.recentOf,
    required this.gridOf,
  });

  /// 面板数据；null = 还在加载 / 读失败，此时只渲染页头 + [placeholder]。
  final TData? data;

  /// 面板切换时间轴（0 = 小说，1 = 短剧）。
  final Animation<double> progress;
  final bool mirrored;
  final double bottomInset;
  final String title;
  final IconData icon;
  final String stats;

  /// 数据未就绪时的占位（加载中 / 读取失败）；高度沿用原来的 220。
  final Widget placeholder;

  /// 最近阅读/观看整块；返回 null 表示这一块不渲染（例如没有阅读记录）。
  final Widget? Function(TData data) recentOf;

  /// 书架/收藏整块（区块标题 + 网格）。
  final Widget Function(TData data) gridOf;

  @override
  Widget build(BuildContext context) {
    final data = this.data;
    final recent = data == null ? null : recentOf(data);
    return Column(
      children: [
        // 页头固定贴顶：不跟着下面列表滚走；切换面板时仍按 100ms 那一拍滑。
        StaggeredBlock(
          progress: progress,
          index: 1,
          incoming: mirrored,
          child: MineHeader(
            title: title,
            icon: icon,
            stats: stats,
            mirrored: mirrored,
          ),
        ),
        Expanded(
          child: CustomScrollView(
            physics: const ClampingScrollPhysics(),
            slivers: [
              if (data != null) ...[
                if (recent != null)
                  SliverToBoxAdapter(
                    child: StaggeredBlock(
                      progress: progress,
                      // 最近块 0 延迟，最先动。
                      index: 0,
                      incoming: mirrored,
                      child: recent,
                    ),
                  ),
                SliverToBoxAdapter(
                  child: StaggeredBlock(
                    progress: progress,
                    // 书架/收藏块第三拍（200ms）。
                    index: 2,
                    incoming: mirrored,
                    child: gridOf(data),
                  ),
                ),
              ] else
                SliverToBoxAdapter(
                  child: StaggeredBlock(
                    progress: progress,
                    index: 0,
                    incoming: mirrored,
                    child: SizedBox(height: 220, child: placeholder),
                  ),
                ),
              // 存储/清缓存入口在「设置」页；这里只留书架与最近阅读/观看。
              SliverToBoxAdapter(child: SizedBox(height: 28 + bottomInset)),
            ],
          ),
        ),
      ],
    );
  }
}
