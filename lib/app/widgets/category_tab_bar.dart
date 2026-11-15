import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 一级分类 tabs 的通用样式（我的页「小说 / 短剧」、推荐页「小说 / 短剧 /
/// 漫剧」共用）。
///
/// 视觉约定：
/// - 默认左对齐；当前 tab 用主题色 + 加粗高亮（**字号不变**），文字正下方有
///   一条**与文字等宽的主色下划线**（小红书式短下划线，不是整行分割线）；
/// - 下划线是一条**跟着切换动画滑动的线**（[TabController.animation]）：点
///   tab 时从原位滑到新位置并顺带改变宽度，左右拖动内容区时跟着手指走；
/// - 文字颜色/字重在滑动过程中**连续插值**（同 [TextStyle.lerp]），不是到
///   中点突然跳变；只有「视觉上选中」的判定（无障碍 selected）在过半时切换；
/// - 默认首个 tab 的文字左边缘与内容留白（8pt）对齐，**槽位宽度按选中态
///   （加粗）预留**：字重变化时左边缘和相邻 tab 都不挪位；
/// - [center] 为 true 时整组 tabs 在可用宽度内居中（推荐页用），居中只影响
///   整行落点，tab 之间的间距/字号规则完全不变；内容超宽时照旧可横向滚动；
/// - 每个 tab 槽位宽度固定、整行高度固定、文字**贴同一条底线**，字号相同，
///   不会推挤邻居；
/// - 下划线**贴在整行底边**：文字底边与行底边之间只隔 [underlineGap] +
///   [underlineHeight]，行内不再留额外下边距，这样「tabs 上边距」与「下划线
///   到下方内容」的两段留白都由调用方（页头 / 内容区）统一决定，两段能做成
///   一样宽。
class CategoryTabBar extends StatefulWidget {
  const CategoryTabBar({
    super.key,
    required this.controller,
    required this.labels,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.center = false,
  }) : assert(labels.length == controller.length);

  /// 整行固定高度（含文字上方的触控留白和下划线）。
  ///
  /// 15pt 字（行盒约 23）+ 顶部 4 + 下划线区 5 = 32：文字上方留 4、下划线
  /// 紧贴文字下方 2pt，整行底边就是下划线底边，调用方在上下各留 8 就是
  /// 等宽的「页头 → tabs」与「下划线 → 内容」。
  static const double height = 32;

  /// tab 字号：选中/未选中**同一个字号**，高亮只靠颜色 + 字重 + 下划线。
  static const double fontSize = 15;

  /// 文字底边到下划线的间距 + 下划线自身高度。
  ///
  /// 两段一起贴在行底：文字底边 → [underlineGap] → 下划线 → 行底边结束。
  static const double underlineGap = 2;
  static const double underlineHeight = 3;

  /// 每个 tab 文字右侧的间距（同时作为该 tab 的尾部可点区域）。
  ///
  /// 左侧不留内边距：首个 tab 的文字左边缘直接贴整行留白，和页头/区块标题对齐；
  /// 宽度仍按**选中字号**预留，所以字号变化时左边缘不动、相邻 tab 也不挪。
  /// [center] 时会在整组前面补上同样一段，让文字块左右留白对称。
  static const double tabGap = 20;

  /// 与 [TabBarView] 共用的 tab 控制器。
  final TabController controller;

  /// 每个 tab 的文案，顺序即索引。
  final List<String> labels;

  /// 整行左右留白（不含 tab 自身的可点留白）。
  final EdgeInsetsGeometry padding;

  /// true = 整组 tabs 在可用宽度内居中；false = 左对齐（默认）。
  ///
  /// 只改整行的落点，不改 tab 之间的间距；可用宽度放不下时仍然是横向滚动，
  /// 滚动内容从留白处开始，不会因为居中而看不到首个 tab。
  final bool center;

  @override
  State<CategoryTabBar> createState() => _CategoryTabBarState();
}

class _CategoryTabBarState extends State<CategoryTabBar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 字号/字重/颜色都在主题字型上覆写（裸 TextStyle 会丢 fontFamily）。
    final base = theme.textTheme.titleMedium ?? const TextStyle();
    final inactiveStyle = base.copyWith(
      fontSize: CategoryTabBar.fontSize,
      fontWeight: context.appWeight(FontWeight.w500),
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.2,
    );
    final activeStyle = base.copyWith(
      fontSize: CategoryTabBar.fontSize,
      fontWeight: context.appWeight(FontWeight.w700),
      color: scheme.primary,
      letterSpacing: 0.2,
    );

    // 宽度按选中态（加粗，两种状态里更宽的那个）预留，字重插值过程中不会
    // 推挤相邻 tab；下划线也按这条宽度算，静止时与选中文字等宽。
    final textWidths = [
      for (final label in widget.labels)
        _measureTextWidth(context, label, activeStyle),
    ];
    final slotWidths = [
      for (final width in textWidths) width + CategoryTabBar.tabGap,
    ];
    // tab 槽位在行内的起点（居中时首个 tab 前面多一段 [tabGap]）。
    final slotStarts = <double>[];
    var slotStart = widget.center ? CategoryTabBar.tabGap : 0.0;
    for (final width in slotWidths) {
      slotStarts.add(slotStart);
      slotStart += width;
    }

    final animation = widget.controller.animation!;
    final row = AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final last = widget.labels.length - 1;
        final t = animation.value.clamp(0.0, last.toDouble());
        final from = t.floor().clamp(0, last);
        final to = math.min(from + 1, last);
        final fraction = t - from;
        final underlineWidth =
            textWidths[from] + (textWidths[to] - textWidths[from]) * fraction;
        final underlineLeft =
            slotStarts[from] + (slotStarts[to] - slotStarts[from]) * fraction;
        return Stack(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 居中时首个 tab 前面补一段尾部留白，文字块左右两侧留白
                // 才相等，视觉上才是真的居中。
                if (widget.center) const SizedBox(width: CategoryTabBar.tabGap),
                for (var i = 0; i < widget.labels.length; i++)
                  _CategoryTab(
                    label: widget.labels[i],
                    width: slotWidths[i],
                    // 颜色/字重连续插值：离当前索引越近越"选中"（字号不变）。
                    style: TextStyle.lerp(
                      inactiveStyle,
                      activeStyle,
                      1 - (t - i).abs().clamp(0.0, 1.0),
                    )!,
                    selected: t.round() == i,
                    onTap: () => widget.controller.animateTo(i),
                  ),
              ],
            ),
            // 一条线滑过所有 tab：点切换时从当前位置滑到目标，拖动内容区时
            // 跟着 animation 的比例走，不再到中点直接跳过去。
            Positioned(
              left: underlineLeft,
              bottom: 0,
              child: Container(
                key: const Key('category_tab_underline'),
                width: underlineWidth,
                height: CategoryTabBar.underlineHeight,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(
                    CategoryTabBar.underlineHeight / 2,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    return SizedBox(
      width: double.infinity,
      height: CategoryTabBar.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = widget.padding.horizontal;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: widget.padding,
            child: widget.center
                ? ConstrainedBox(
                    // 放得下时把行撑满可用宽度再居中；放不下时按内容宽度
                    // 撑开，退化成横向滚动。
                    constraints: BoxConstraints(
                      minWidth: math.max(
                        0.0,
                        constraints.maxWidth - horizontalPadding,
                      ),
                    ),
                    child: Center(child: row),
                  )
                : row,
          );
        },
      ),
    );
  }

  /// 用选中态字型量出文字宽度：既用于 tab 槽位宽度（再加 [tabGap]），
  /// 也用于下划线宽度（与选中态文字等宽）。
  double _measureTextWidth(
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
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.label,
    required this.width,
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// 整格宽度（文字宽度 + [CategoryTabBar.tabGap] 的尾部可点区域）。
  final double width;

  /// 当前帧的文字样式（颜色/字重已按动画进度插值；字号固定）。
  final TextStyle style;

  /// 无障碍语义上的选中态：过半即切换（视觉上早就开始渐变）。
  final bool selected;
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
            // 左下对齐：左边缘始终贴内容留白；文字贴行底上方 [underlineGap]
            // + [underlineHeight] 处，底线固定。
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.only(
                bottom:
                    CategoryTabBar.underlineGap +
                    CategoryTabBar.underlineHeight,
              ),
              child: Text(label, maxLines: 1, style: style),
            ),
          ),
        ),
      ),
    );
  }
}
