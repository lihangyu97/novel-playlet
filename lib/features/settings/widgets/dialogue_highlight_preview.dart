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
///
/// 分页结果只跟可用宽度 / 字型 / textScaler / 明暗有关，与荧光笔颜色无关，
/// 所以在 State 里按这四项 memo：取色器拖动时每帧都会重建本组件，颜色变化
/// 只应重画色带，不能每帧重跑一遍 ReaderPagination.build。
class DialogueHighlightPreview extends StatefulWidget {
  const DialogueHighlightPreview({super.key, required this.color});

  final Color color;

  /// 真正执行 `ReaderPagination.build` 的次数。
  ///
  /// 只给测试用：锁住「连续换色不触发重新分页」这条性能约定。
  @visibleForTesting
  static int debugPaginationBuilds = 0;

  static const List<String> sampleParagraphs = [
    '他抬头看了她一眼，语气平静。',
    '“你先别急着走，把话说清楚。”',
    '她站在门口，没有让开。',
  ];

  @override
  State<DialogueHighlightPreview> createState() =>
      _DialogueHighlightPreviewState();
}

/// 分页缓存键：只有这四项变化才需要重新分页。
typedef _PaginationKey = ({
  double contentWidth,
  TextScaler textScaler,
  Brightness brightness,
  String? fontFamily,
});

class _PaginationCache {
  const _PaginationCache({
    required this.page,
    required this.pageHeight,
    required this.textStyle,
    required this.textScaler,
    required this.contentWidth,
  });

  final ReaderPage? page;
  final double pageHeight;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final double contentWidth;
}

class _DialogueHighlightPreviewState extends State<DialogueHighlightPreview> {
  _PaginationKey? _cacheKey;
  _PaginationCache? _cache;

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
        final key = (
          contentWidth: contentWidth,
          textScaler: textScaler,
          brightness: theme.brightness,
          fontFamily: theme.textTheme.bodyMedium?.fontFamily,
        );
        var cache = _cache;
        if (cache == null || _cacheKey != key) {
          cache = _build(contentWidth, textStyle, textScaler);
          _cache = cache;
          _cacheKey = key;
        }
        return Container(
          key: const Key('dialogue-highlight-preview'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: paper.background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: cache.page == null
              ? const SizedBox(height: 40)
              : SizedBox(
                  height: cache.pageHeight,
                  child: ReaderPageContent(
                    page: cache.page!,
                    textStyle: cache.textStyle,
                    textScaler: cache.textScaler,
                    contentWidth: cache.contentWidth,
                    horizontalPadding: 0,
                    // 只有它每帧在变：重画色带即可，分页已缓存。
                    dialogueHighlightColor: widget.color,
                  ),
                ),
        );
      },
    );
  }

  _PaginationCache _build(
    double contentWidth,
    TextStyle textStyle,
    TextScaler textScaler,
  ) {
    DialogueHighlightPreview.debugPaginationBuilds++;
    final pagination = ReaderPagination.build(
      chapterId: 'dialogue-highlight-preview',
      paragraphs: DialogueHighlightPreview.sampleParagraphs,
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
    return _PaginationCache(
      page: page,
      pageHeight: pageHeight,
      textStyle: textStyle,
      textScaler: textScaler,
      contentWidth: contentWidth,
    );
  }
}
