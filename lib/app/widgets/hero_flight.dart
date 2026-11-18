import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// 详情页里跟封面一起飞入的「文字 / 评分」字段 tag。
///
/// 全部从封面 tag 派生：卡片侧和详情侧拿到的是同一个 `heroTag`，所以入口处
/// 不用再为每个字段各传一份 tag（路由参数保持一个 `heroTag` 不变）。tag 只
/// 要在一个路由内唯一即可，派生规则保证「同一张卡片的字段不会互相撞」。
class HeroFieldTag {
  const HeroFieldTag._();

  static String title(String coverTag) => '$coverTag/title';

  /// 作者，短剧是「全 N 集」。
  static String subtitle(String coverTag) => '$coverTag/subtitle';

  static String score(String coverTag) => '$coverTag/score';
}

/// 文字 Hero：飞行中按两端字号/颜色重新排版，而不是让默认 Hero 把字形拉伸。
///
/// 默认 Hero 会把目标 widget 塞进插值出来的矩形里，文字会被压扁/拉长；这里
/// 用自定义 shuttle：飞行期间用两端的 [TextStyle] 做插值做一次真实 layout，
/// 字形始终清晰。两端文字内容不一致时（例如卡片只显示作者、详情是
/// 「作者 · 连载中 · 132.8万字」），起飞阶段先画卡片那一份，中途换到详情
/// 那一份，避免第一帧就和卡片对不上。
class HeroText extends StatelessWidget {
  const HeroText({
    super.key,
    required this.tag,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
  });

  /// null = 不参与飞行，原样渲染（深链/没有来源卡片时）。
  final String? tag;
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    // 在这里把 DefaultTextStyle 合进来：飞行层在 Overlay 里，拿不到卡片/详情
    // 的默认字体族，不合就会在飞行途中掉回系统默认字体（中文字形都不一样）。
    final child = Text(
      text,
      style: _resolveStyle(context, style),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
    final tag = this.tag;
    if (tag == null) return child;
    return Hero(
      tag: tag,
      // iOS 边缘侧滑返回也要飞，否则手势转场里文字会直接消失。
      transitionOnUserGestures: true,
      flightShuttleBuilder: _flight,
      child: child,
    );
  }
}

Widget _flight(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromContext,
  BuildContext toContext,
) {
  final from = _textOf(fromContext);
  final to = _textOf(toContext);
  final fromStyle = _lerpableStyle(from.style);
  final toStyle = _lerpableStyle(to.style);
  final same = from.data == to.data;
  final fromWidth = _sizeOf(fromContext)?.width ?? 0;
  final toWidth = _sizeOf(toContext)?.width ?? 0;

  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      // 关键：字号（以及内容切换）跟着**飞行矩形的宽度**走，而不是跟着
      // animation.value 走。
      //
      // Hero 的矩形和动画进度之间隔着一层曲线/方向处理，二者会差出十几到
      // 几十毫秒：字号按进度插值、矩形按自己的节奏走时，就会出现「矩形已经
      // 缩到卡片宽度，字号还是详情那么大」——长标题在这一刻顶出卡片，短标题
      // 「剑来」被挤成两行。
      //
      // 现在改成用矩形宽度反推进度：起点正好是卡片自己的宽度/字号，终点正好
      // 是详情自己的，中途按矩形宽度重排 + 等比缩字号，文字永远贴着卡片。
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final span = toWidth - fromWidth;
          final fallback = direction == HeroFlightDirection.push
              ? animation.value
              : 1 - animation.value;
          final t = span.abs() < 0.01
              ? fallback
              : ((width - fromWidth) / span).clamp(0.0, 1.0);
          final style = TextStyle.lerp(fromStyle, toStyle, t);
          final text = same || t >= 0.45 ? to : from;
          // 比矩形宽一点点（2% + 2px）：两端宽度/字号比例不严格相等，正好
          // 卡边界时两个字会被挤成竖排两行。矩形是紧约束，用 OverflowBox
          // 放开才能让这 2% 生效。
          return OverflowBox(
            alignment: AlignmentDirectional.topStart,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: SizedBox(
              width: width * 1.02 + 2,
              child: Text(
                text.data ?? '',
                style: style,
                softWrap: true,
                overflow: TextOverflow.visible,
                textAlign: text.textAlign,
              ),
            ),
          );
        },
      );
    },
  );
}

Size? _sizeOf(BuildContext heroContext) {
  final box = heroContext.findRenderObject();
  return box is RenderBox && box.hasSize ? box.size : null;
}

Text _textOf(BuildContext heroContext) {
  final hero = heroContext.widget as Hero;
  final child = hero.child;
  if (child is Text) return child;
  throw FlutterError(
    'HeroText 的 child 只能是 Text（实际是 ${child.runtimeType}）：'
    '飞行中要按两端的 TextStyle 重新排版。',
  );
}

/// 合并当前 DefaultTextStyle，得到完整的渲染样式（字体族/颜色/字号都在里面）。
TextStyle _resolveStyle(BuildContext context, TextStyle? style) {
  final base = DefaultTextStyle.of(context).style;
  return style == null ? base : base.merge(style);
}

/// 把样式统一成「两端都能插值」的形态。
///
/// Material 的 TextTheme 样式是 `inherit: false`，卡片角标这类手写样式是
/// `inherit: true`；[TextStyle.lerp] 对 inherit 不一致的两端会断言失败。两端
/// 的样式都由调用方显式传全（主题样式/角标样式都带齐字段），这里只需要把
/// inherit 统一；不查 Hero 的祖先（Hero 在飞行结束时可能已经 deactivated）。
TextStyle _lerpableStyle(TextStyle? style) =>
    (style ?? const TextStyle()).copyWith(inherit: true);

/// 评分 Hero：卡片封面角标「9.3分」↔ 详情行内「★ 9.3」。
///
/// 两端形态完全不同（角标是白字深底胶囊，详情是主色星标 + 正文色分数），
/// 所以 shuttle 不搬运 widget：按飞行进度插值颜色，把目标形态（星标 + 分数）
/// 缩放进飞行矩形——视觉上就是「角标里的数字长大、星标从左侧长出来」。
class HeroScore extends StatelessWidget {
  const HeroScore._({
    super.key,
    required this.tag,
    required this.score,
    required this.label,
    required this.style,
    required this.starSize,
    required this.starColor,
    required this.pill,
  });

  /// 卡片封面右上角角标（显示「9.3分」）。
  factory HeroScore.badge({
    Key? key,
    required String? tag,
    required String score,
    TextStyle? style,
  }) => HeroScore._(
    key: key,
    tag: tag,
    score: score,
    label: '$score分',
    style: style ?? const TextStyle(),
    starSize: 0,
    starColor: const Color(0x00000000),
    pill: true,
  );

  /// 详情页行内的「★ 分数」；[label] 给列表侧显示成「9.3分」这类文案用。
  factory HeroScore.inline({
    Key? key,
    required String? tag,
    required String score,
    String? label,
    required TextStyle? style,
    double starSize = 17,
    required Color starColor,
  }) => HeroScore._(
    key: key,
    tag: tag,
    score: score,
    label: label ?? score,
    style: style ?? const TextStyle(),
    starSize: starSize,
    starColor: starColor,
    pill: false,
  );

  final String? tag;
  final String score;

  /// 静止状态下显示的文案（角标带「分」，详情只有数字）。
  final String label;
  final TextStyle style;
  final double starSize;
  final Color starColor;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final child = _ScoreChip(
      label: label,
      style: _resolveStyle(context, style),
      starSize: starSize,
      starColor: starColor,
      pill: pill,
    );
    final tag = this.tag;
    if (tag == null) return child;
    return Hero(
      tag: tag,
      transitionOnUserGestures: true,
      flightShuttleBuilder: _scoreFlight,
      child: child,
    );
  }
}

class _ScoreChip extends StatelessWidget {
  const _ScoreChip({
    required this.label,
    required this.style,
    required this.starSize,
    required this.starColor,
    required this.pill,
  });

  final String label;
  final TextStyle style;
  final double starSize;
  final Color starColor;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (starSize > 0) ...[
          Icon(Icons.star_rounded, size: starSize, color: starColor),
          const SizedBox(width: 3),
        ],
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ],
    );
    if (!pill) return row;
    // 与卡片的 `_CornerBadge` 同一套样式：白字 + 半透明深底 + 轻阴影。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: row,
    );
  }
}

Widget _scoreFlight(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromContext,
  BuildContext toContext,
) {
  final from = _chipOf(fromContext);
  final to = _chipOf(toContext);
  final fromStyle = _lerpableStyle(from.style);
  final toStyle = _lerpableStyle(to.style);

  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      // 字号/星标尺寸/颜色都跟着同一个进度线性插值；不再用 FittedBox 按矩形
      // 缩放（宽高两条边界取 min，途中大小会先缩再涨）。
      final style = TextStyle.lerp(fromStyle, toStyle, t)!;
      final starColor =
          Color.lerp(from.starColor, to.starColor, t) ?? to.starColor;
      final starSize = lerpDouble(from.starSize, to.starSize, t) ?? 0;
      final label = t < 0.5 ? from.label : to.label;
      // 飞行矩形比内容窄时，Row 会触发 debug 的 overflow 条纹：用 OverflowBox
      // 给内容无界约束（按自然尺寸排版），超出矩形的部分照常画出去。
      return OverflowBox(
        alignment: AlignmentDirectional.centerStart,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: _ScoreChip(
          label: label,
          style: style,
          starSize: starSize,
          starColor: starColor,
          pill: false,
        ),
      );
    },
  );
}

_ScoreChip _chipOf(BuildContext heroContext) {
  final hero = heroContext.widget as Hero;
  final child = hero.child;
  if (child is _ScoreChip) return child;
  throw FlutterError(
    'HeroScore 的 child 只能是 _ScoreChip（实际是 ${child.runtimeType}）。',
  );
}
