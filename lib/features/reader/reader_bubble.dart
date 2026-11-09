import 'package:flutter/material.dart';

import '../../data/models/chapter_ideas.dart';

/// 段评气泡的尾巴高度（逻辑值，未乘缩放）：气泡本体 = 盒子高度减尾巴，
/// 数字只在气泡本体内居中，避免被尾巴顶偏。
const double _bubbleTailHeight = 4;

/// 段尾段评气泡。
///
/// 官方用 APK 里的皮肤图（本仓库没有素材，也不能加依赖），这里用主题色画一个
/// **空心对话气泡**近似：透明底 + 描边 + 左下小尾巴，数字居中；三种 variant
/// 只区分描边/数字配色（普通 / 有读者 / 作者），文案是该段评论数，>99 显示
/// 99+——与官方口径一致。
///
/// 尺寸是**未缩放**的逻辑值：分页测量时 PlaceholderDimensions 会乘上系统字体
/// 缩放，RenderParagraph 渲染 WidgetSpan 时也会做同样的缩放，两边必须同源
/// （见 reader_pagination.buildReaderParagraphSpan）。
class ReaderParagraphBubble extends StatelessWidget {
  const ReaderParagraphBubble({
    super.key,
    required this.count,
    required this.variant,
    this.onTap,
    this.scaled = true,
  });

  final int count;
  final ParagraphBubbleVariant variant;
  final VoidCallback? onTap;

  /// 测量用的占位不需要点击/文字缩放，渲染时才用真实内容。
  final bool scaled;

  /// 气泡盒子尺寸与段末间距（逻辑值，未乘缩放）。
  static const double boxWidth = 30;
  static const double boxHeight = 20;
  static const double gap = 8;

  /// 描边宽度（逻辑值，不随系统字体缩放）。
  static const double _strokeWidth = 1.2;

  String get label => count > 99 ? '99+' : '$count';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (variant) {
      ParagraphBubbleVariant.author => scheme.tertiary,
      ParagraphBubbleVariant.users => scheme.primary,
      ParagraphBubbleVariant.plain => scheme.onSurfaceVariant,
    };
    final box = SizedBox(
      width: boxWidth,
      height: boxHeight,
      child: CustomPaint(
        painter: _BubbleOutlinePainter(
          color: color,
          strokeWidth: _strokeWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: _bubbleTailHeight),
          child: Center(
            child: Text(
              scaled ? label : '',
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
    final tappable = onTap == null
        ? box
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: box,
          );
    return Padding(
      padding: const EdgeInsets.only(left: gap),
      child: tappable,
    );
  }
}

/// 空心对话气泡描边：圆角矩形 + 左下小尾巴，只描边不填充。
class _BubbleOutlinePainter extends CustomPainter {
  const _BubbleOutlinePainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = color;
    // 内缩半个描边，避免线条正好压在 WidgetSpan 边界上被裁掉。
    final inset = strokeWidth / 2;
    final left = inset;
    final right = size.width - inset;
    final top = inset;
    final bottom = size.height - _bubbleTailHeight;
    // 极端缩放（盒高不大于尾巴）时没有可画的本体，直接跳过，避免负圆角。
    if (bottom <= top) return;
    final radius = (bottom - top) / 2;
    // 尾巴在左下：沿底边从右往左走时先下探再回到底边。
    final tailLeft = size.width * 0.34;
    final tailRight = size.width * 0.54;
    final tailTip = Offset(size.width * 0.42, size.height - inset);

    final path = Path()
      ..moveTo(left + radius, top)
      ..lineTo(right - radius, top)
      ..arcToPoint(
        Offset(right, top + radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(right, bottom - radius)
      ..arcToPoint(
        Offset(right - radius, bottom),
        radius: Radius.circular(radius),
      )
      ..lineTo(tailRight, bottom)
      ..lineTo(tailTip.dx, tailTip.dy)
      ..lineTo(tailLeft, bottom)
      ..lineTo(left + radius, bottom)
      ..arcToPoint(
        Offset(left, bottom - radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(left, top + radius)
      ..arcToPoint(
        Offset(left + radius, top),
        radius: Radius.circular(radius),
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleOutlinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
