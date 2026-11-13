import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/widgets/app_bottom_sheet.dart';
import '../../../data/models/chapter.dart';

/// 选集弹层每个 tab 的集数：78 集 = 13 行 × 6 列，正好比一屏多一点。
///
/// 弹层高度只有 0.7 屏，1000+ 集整页平铺会铺出几十屏空白；按 78 集分 tab 后
/// 最多横向滑几下就能定位（tab 标签直接写集数区间）。详情页的内嵌选集用
/// 36 集/tab 是因为那里还要展开/收起，两者互不影响。
const int episodesPerTab = 78;

/// 打开「选集」底部弹层，返回被选中的集下标（取消返回 null）。
///
/// 与阅读器的目录弹层同款交互：底部弹层 + tab 分组 + 网格快速跳集。集数只
/// 显示数字（不写「第 x 集」），一行 6 个，长剧也能两三下翻到目标集。
Future<int?> showEpisodePickerSheet(
  BuildContext context, {
  required List<Chapter> episodes,
  required int currentIndex,
  required String seriesTitle,
}) {
  return showAppBottomSheet<int>(
    context: context,
    builder: (_) => _EpisodePickerBody(
      episodes: episodes,
      currentIndex: currentIndex,
      seriesTitle: seriesTitle,
    ),
  );
}

class _EpisodePickerBody extends StatefulWidget {
  const _EpisodePickerBody({
    required this.episodes,
    required this.currentIndex,
    required this.seriesTitle,
  });

  final List<Chapter> episodes;
  final int currentIndex;
  final String seriesTitle;

  @override
  State<_EpisodePickerBody> createState() => _EpisodePickerBodyState();
}

class _EpisodePickerBodyState extends State<_EpisodePickerBody>
    with TickerProviderStateMixin {
  late final TabController _tabController;

  int get _tabCount => (widget.episodes.length / episodesPerTab).ceil();

  /// 打开时定位到当前集所在的 tab：用户在第 500 集就落到 469-546 那页。
  int get _initialTab => (widget.currentIndex ~/ episodesPerTab).clamp(
    0,
    math.max(0, _tabCount - 1),
  );

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: math.max(1, _tabCount),
      initialIndex: _initialTab,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放页不会用空选集打开弹层；仍然防一下 TabBar 对 tabs 数量的断言。
    if (_tabCount == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBottomSheet(
      title: '选集',
      subtitle: '共 ${widget.episodes.length} 集 · ${widget.seriesTitle}',
      heightFactor: 0.7,
      closeTooltip: '关闭选集',
      // tab 样式与详情页选集一致：可横向滑动，内容可左右滑。
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            labelPadding: const EdgeInsets.symmetric(horizontal: 10),
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
            ),
            indicatorSize: TabBarIndicatorSize.label,
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(width: 2, color: scheme.primary),
              insets: const EdgeInsets.symmetric(horizontal: 2),
            ),
            dividerColor: Colors.transparent,
            tabs: [
              for (var tab = 0; tab < _tabCount; tab++)
                Tab(height: 40, text: _tabLabel(tab)),
            ],
          ),
          // 78 集（13 行）放不进 0.7 屏高的弹层，每个 tab 内单独滚动。
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (var tab = 0; tab < _tabCount; tab++) _buildGrid(tab),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// tab 标签用集数区间：1-78、79-156、157-200，只有一集时显示单个数字。
  String _tabLabel(int tab) {
    final start = tab * episodesPerTab + 1;
    final end = math.min((tab + 1) * episodesPerTab, widget.episodes.length);
    return start == end ? '$start' : '$start-$end';
  }

  Widget _buildGrid(int tab) {
    final start = tab * episodesPerTab;
    final end = math.min(start + episodesPerTab, widget.episodes.length);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 44,
      ),
      itemCount: end - start,
      itemBuilder: (context, localIndex) {
        final index = start + localIndex;
        final selected = index == widget.currentIndex;
        final label = Text(
          '${index + 1}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected ? scheme.onPrimary : scheme.onSurface,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        );
        void onTap() => Navigator.of(context).pop(index);
        return selected
            ? FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: label,
              )
            : OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: label,
              );
      },
    );
  }
}
