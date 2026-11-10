import 'package:flutter/material.dart';

/// 一级分类 tabs 的通用样式（我的页「小说 / 短剧」、推荐页「小说 / 短剧 /
/// 漫剧」共用）。
///
/// 视觉约定：
/// - 左对齐、**无下划线/指示条**；当前 tab 用主题色高亮、字号比未选中略大；
/// - 每个 tab 宽度固定、整行高度固定、文字**贴同一条底线**：选中/未选中只
///   有"字号 15 / 17"两种确定状态，变大的字只向上长，不会推挤邻居；
/// - 高亮跟随 [TabController.animation] 的**过半阈值**切换（拖动时一过中线
///   就切，不等翻页结束），但字号/颜色都**不做逐帧插值**——两种状态各自
///   像素稳定，避免字号连续变化导致文字每帧重排、重栅格化带来的"抖动"。
class CategoryTabBar extends StatefulWidget {
  const CategoryTabBar({
    super.key,
    required this.controller,
    required this.labels,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  }) : assert(labels.length == controller.length);

  /// 整行固定高度（含上下触控留白）。
  static const double height = 44;

  /// 未选中 / 选中字号，两者差值就是高亮时的"放大"幅度。
  static const double fontSize = 15;
  static const double selectedFontSize = 17;

  /// 每个 tab 的左右可点留白（宽度按选中态文字 + 两边留白预留）。
  static const double _itemPadding = 10;

  /// 与 [TabBarView] 共用的 tab 控制器。
  final TabController controller;

  /// 每个 tab 的文案，顺序即索引。
  final List<String> labels;

  /// 整行左右留白（不含 tab 自身的可点留白）。
  final EdgeInsetsGeometry padding;

  @override
  State<CategoryTabBar> createState() => _CategoryTabBarState();
}

class _CategoryTabBarState extends State<CategoryTabBar> {
  /// 当前高亮的 tab。只在"过半切换"时 setState，动画中间帧不重建。
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.controller.index;
    widget.controller.animation!.addListener(_handleAnimationTick);
  }

  @override
  void didUpdateWidget(CategoryTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.animation?.removeListener(_handleAnimationTick);
      _selectedIndex = widget.controller.index;
      widget.controller.animation!.addListener(_handleAnimationTick);
    }
  }

  @override
  void dispose() {
    widget.controller.animation?.removeListener(_handleAnimationTick);
    super.dispose();
  }

  void _handleAnimationTick() {
    final animation = widget.controller.animation;
    if (animation == null || !mounted) return;
    // round：0.5 时归到后一个 tab，语义就是「过半立即切换」。
    final next = animation.value.round().clamp(0, widget.labels.length - 1);
    if (next != _selectedIndex) {
      setState(() => _selectedIndex = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 字号/字重/颜色都在主题字型上覆写（裸 TextStyle 会丢 fontFamily）。
    final base = theme.textTheme.titleMedium ?? const TextStyle();
    final inactiveStyle = base.copyWith(
      fontSize: CategoryTabBar.fontSize,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.2,
    );
    final activeStyle = base.copyWith(
      fontSize: CategoryTabBar.selectedFontSize,
      fontWeight: FontWeight.w700,
      color: scheme.primary,
      letterSpacing: 0.2,
    );

    // 宽度按选中态预留（两种状态里更宽的那个），切换时不会推挤相邻 tab；
    // 行高按选中态量出来，把两类文字固定贴在同一条底线上。
    final labelMetrics = [
      for (final label in widget.labels)
        _measureLabel(context, label, activeStyle),
    ];
    final slotWidths = [for (final metric in labelMetrics) metric.width];
    final lineHeight = labelMetrics.first.lineHeight;
    final labelBottomInset = lineHeight >= CategoryTabBar.height
        ? 0.0
        : (CategoryTabBar.height - lineHeight) / 2;

    // 撑满一行：tabs 按起始端左对齐（不要被外层 Column 居中），超宽时才滚动。
    return SizedBox(
      width: double.infinity,
      height: CategoryTabBar.height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        padding: widget.padding,
        child: Row(
          children: [
            for (var i = 0; i < widget.labels.length; i++)
              _CategoryTab(
                label: widget.labels[i],
                width: slotWidths[i],
                bottomInset: labelBottomInset,
                selected: i == _selectedIndex,
                inactiveStyle: inactiveStyle,
                activeStyle: activeStyle,
                onTap: () => widget.controller.animateTo(i),
              ),
          ],
        ),
      ),
    );
  }

  /// 用选中态字型量出宽度（含左右可点区域）和单行行高。
  ({double width, double lineHeight}) _measureLabel(
    BuildContext context,
    String label,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final metric = (
      width: painter.width + CategoryTabBar._itemPadding * 2,
      lineHeight: painter.height,
    );
    painter.dispose();
    return metric;
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.width,
    required this.bottomInset,
    required this.selected,
    required this.inactiveStyle,
    required this.activeStyle,
    required this.onTap,
  });

  final String label;
  final double width;

  /// 文字底边距格子底边的距离：选中/未选中都贴在这条线上，字号变化只向上长。
  final double bottomInset;
  final bool selected;
  final TextStyle inactiveStyle;
  final TextStyle activeStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: width,
          height: CategoryTabBar.height,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Text(
                label,
                maxLines: 1,
                textAlign: TextAlign.center,
                style: selected ? activeStyle : inactiveStyle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
