import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/widgets/detail/detail_common.dart';
import '../../../data/models/chapter.dart';

/// 短剧详情里的选集：默认折叠，展开后按固定集数自动分 tab。
///
/// 上游有些剧 1000+ 集，如果像以前那样平铺一整个 grid，详情页会被撑成灾难。
/// 这里每 36 集一组、组内每行 6 个，tab 样式与推荐页的分类 tabs 一致（可横向
/// 滑动、内容可左右滑）；折叠态只保留一行「选集 / 共 N 集 / 展开」。
class EpisodePicker extends StatefulWidget {
  const EpisodePicker({
    super.key,
    required this.episodes,
    required this.onOpen,
    this.initiallyExpanded = false,
    this.episodesPerTab = 36,
    this.columns = 6,
  });

  final List<Chapter> episodes;

  /// 回传整部剧里的绝对下标。
  final ValueChanged<int> onOpen;

  final bool initiallyExpanded;
  final int episodesPerTab;
  final int columns;

  static const double buttonHeight = 34;
  static const double buttonSpacing = 6;

  @override
  State<EpisodePicker> createState() => _EpisodePickerState();
}

class _EpisodePickerState extends State<EpisodePicker>
    with TickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;
  TabController? _tabController;

  int get _tabCount => (widget.episodes.length / widget.episodesPerTab).ceil();

  @override
  void initState() {
    super.initState();
    _ensureController();
  }

  @override
  void didUpdateWidget(EpisodePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodes.length != widget.episodes.length ||
        oldWidget.episodesPerTab != widget.episodesPerTab) {
      _ensureController();
    }
  }

  void _ensureController() {
    final count = math.max(1, _tabCount);
    if (_tabController?.length == count) return;
    _tabController?.dispose();
    _tabController = TabController(length: count, vsync: this);
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = widget.episodes.length;

    return Column(
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              detailGutter,
              detailGutter,
              detailGutter,
              4,
            ),
            child: Row(
              children: [
                Text(
                  '选集',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '共 $total 集',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubicEmphasized,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _buildExpanded(context)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildExpanded(BuildContext context) {
    final controller = _tabController!;
    final tabCount = _tabCount;
    final rowsPerTab = (widget.episodesPerTab / widget.columns).ceil();
    final gridHeight =
        rowsPerTab * (EpisodePicker.buttonHeight + EpisodePicker.buttonSpacing) -
        EpisodePicker.buttonSpacing;

    return Column(
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          labelPadding: const EdgeInsets.symmetric(horizontal: 10),
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
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
            borderSide: BorderSide(
              width: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
            insets: const EdgeInsets.symmetric(horizontal: 2),
          ),
          dividerColor: Colors.transparent,
          tabs: [
            for (var tab = 0; tab < tabCount; tab++)
              Tab(height: 40, text: _tabLabel(tab)),
          ],
        ),
        SizedBox(
          height: gridHeight + 8,
          child: TabBarView(
            controller: controller,
            children: [
              for (var tab = 0; tab < tabCount; tab++) _buildGrid(tab),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  String _tabLabel(int tab) {
    final start = tab * widget.episodesPerTab + 1;
    final end = math.min(
      (tab + 1) * widget.episodesPerTab,
      widget.episodes.length,
    );
    return start == end ? '$start' : '$start-$end';
  }

  Widget _buildGrid(int tab) {
    final start = tab * widget.episodesPerTab;
    final end = math.min(
      start + widget.episodesPerTab,
      widget.episodes.length,
    );
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(detailGutter, 4, detailGutter, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = ((constraints.maxWidth -
                      (widget.columns - 1) * EpisodePicker.buttonSpacing) /
                  widget.columns)
              .floorToDouble();
          return Wrap(
            spacing: EpisodePicker.buttonSpacing,
            runSpacing: EpisodePicker.buttonSpacing,
            children: [
              for (var index = start; index < end; index++)
                SizedBox(
                  width: itemWidth,
                  height: EpisodePicker.buttonHeight,
                  child: OutlinedButton(
                    onPressed: () => widget.onOpen(index),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      textStyle: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                      ),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    // 1000+ 集的剧只需要集数：去掉「第…集」前后缀。
                    child: Text('${index + 1}'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
