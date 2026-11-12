import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../reader/reader_pagination.dart';
import '../../reader/reader_widgets.dart';

/// 取色弹层里的「对话高亮」示例：直接用阅读页的真实正文渲染（含段落缩进、
/// 行高、荧光笔色带），选色时能立刻看到实际效果。
///
/// 预览按当前 App 深浅色挑一张阅读底色（浅色用纸色、深色用夜间纸），
/// 透明度和真实阅读页一致（由 ReaderPageContent 按亮暗叠）。
class DialogueHighlightPreview extends StatelessWidget {
  const DialogueHighlightPreview({super.key, required this.color});

  final Color color;

  static const List<String> _sampleParagraphs = [
    '他抬头看了她一眼，语气平静。',
    '“你先别急着走，把话说清楚。”',
    '她站在门口，没有让开。',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.brightness == Brightness.dark
        ? ReaderPaper.night
        : ReaderPaper.parchment;
    final textStyle =
        AppTheme.readerText(
          fontSize: 17,
          lineHeight: 1.7,
          color: paper.foreground,
        ).copyWith(
          inherit: false,
          fontFamily: theme.textTheme.bodyMedium?.fontFamily,
        );
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(0.0, constraints.maxWidth - 24);
        final pagination = ReaderPagination.build(
          chapterId: 'dialogue-highlight-preview',
          paragraphs: _sampleParagraphs,
          spec: ReaderLayoutSpec(
            width: contentWidth,
            height: 420,
            textScaler: textScaler,
            bodyStyle: textStyle,
            paragraphSpacing: 17 * 0.55,
          ),
        );
        final page = pagination.pages.isEmpty ? null : pagination.pages.first;
        final pageHeight = page == null
            ? 0.0
            : page.fragments.fold<double>(
                0,
                (height, fragment) =>
                    math.max(height, fragment.top + fragment.height),
              );
        return Container(
          key: const Key('dialogue-highlight-preview'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: paper.background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: page == null
              ? const SizedBox(height: 40)
              : SizedBox(
                  height: pageHeight,
                  child: ReaderPageContent(
                    page: page,
                    textStyle: textStyle,
                    textScaler: textScaler,
                    contentWidth: contentWidth,
                    horizontalPadding: 0,
                    dialogueHighlightColor: color,
                  ),
                ),
        );
      },
    );
  }
}
