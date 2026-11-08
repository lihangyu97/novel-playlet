import 'package:flutter/material.dart';

import '../../data/models/chapter_ideas.dart';

/// 段尾段评气泡。
///
/// 官方用 APK 里的皮肤图（本仓库没有素材，也不能加依赖），这里用主题色画一个
/// 小圆角徽标近似：三种 variant 只区分配色（普通 / 有读者 / 作者），文案是
/// 该段评论数，>99 显示 99+——与官方口径一致。
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

  String get label => count > 99 ? '99+' : '$count';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (variant) {
      ParagraphBubbleVariant.author => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      ParagraphBubbleVariant.users => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ParagraphBubbleVariant.plain => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    final box = Container(
      width: boxWidth,
      height: boxHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(boxHeight / 2),
      ),
      child: Text(
        scaled ? label : '',
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w600,
          color: foreground,
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
