import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 正文的行高行为。测量（TextPainter）与渲染（Text）必须显式传同一份，
/// 否则两组默认值不同时（比如 DefaultTextStyle 带了 leadingDistribution）
/// 行高会差一两个像素，翻到最后几页就会看到文字被切掉半行。
const TextHeightBehavior readerTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
  leadingDistribution: TextLeadingDistribution.proportional,
);

/// 段首缩进两个汉字宽。用全角空格拼进文本而不是 WidgetSpan，测量和渲染
/// 用的是同一份字符串，不需要给 TextPainter 设置占位符。
const String readerParagraphIndent = '　　';

/// 分页的几何输入。
///
/// 刻意不含文字颜色：换底色只换颜色、不改变度量，阅读位置不该因此重排。
@immutable
class ReaderLayoutSpec {
  const ReaderLayoutSpec({
    required this.width,
    required this.height,
    required this.textScaler,
    required this.bodyStyle,
    required this.paragraphSpacing,
  });

  /// 一行正文可用的宽度（已扣掉左右内边距）。
  final double width;

  /// 一页可用的高度。
  final double height;

  /// 系统字体缩放（设置里的字号之外，用户的无障碍字号也要生效）。
  final TextScaler textScaler;

  /// 与渲染完全一致的正文样式。
  final TextStyle bodyStyle;

  /// 段间距。
  final double paragraphSpacing;
}

/// 一个段落的测量结果：整段文字、占位高度、每一行在段内的纵向位置。
///
/// 分页时只在行边界切页，渲染时把整段 Text 按行偏移裁剪，所以行断点
/// 永远来自同一次 TextPainter 测量，不会因为二次排版而错位。
@immutable
class ReaderBlock {
  ReaderBlock({
    required this.index,
    required this.text,
    required this.height,
    required List<double> lineTops,
    required List<double> lineHeights,
  }) : lineTops = List<double>.unmodifiable(lineTops),
       lineHeights = List<double>.unmodifiable(lineHeights);

  final int index;
  final String text;
  final double height;
  final List<double> lineTops;
  final List<double> lineHeights;

  int get lineCount => lineTops.length;
}

/// 页面上一段被裁剪出来的文字。
@immutable
class ReaderFragment {
  const ReaderFragment({
    required this.block,
    required this.firstLine,
    required this.lastLine,
    required this.top,
  });

  final ReaderBlock block;
  final int firstLine;
  final int lastLine;

  /// 在页面坐标系里的顶部位置。
  final double top;

  /// 段内第一行的顶部位置；渲染时用它把整段向上平移。
  double get sourceTop => block.lineTops[firstLine];

  double get height =>
      block.lineTops[lastLine] + block.lineHeights[lastLine] - sourceTop;

  ReaderFragment extendedTo(int line) => ReaderFragment(
    block: block,
    firstLine: firstLine,
    lastLine: line,
    top: top,
  );
}

/// 一页：若干段落片段，按纵向顺序排列。
@immutable
class ReaderPage {
  const ReaderPage(this.fragments);

  final List<ReaderFragment> fragments;

  int get firstBlockIndex => fragments.first.block.index;
}

/// 一章的分页结果。
class ReaderPagination {
  ReaderPagination._({
    required this.chapterId,
    required this.blocks,
    required this.pages,
  });

  /// 正文所属章节 id。页面用它判断“换章了”，从而重置 PageView。
  final String chapterId;
  final List<ReaderBlock> blocks;
  final List<ReaderPage> pages;

  static const double _epsilon = 0.001;

  factory ReaderPagination.build({
    required String chapterId,
    required List<String> paragraphs,
    required ReaderLayoutSpec spec,
  }) {
    final blocks = <ReaderBlock>[];
    for (final paragraph in paragraphs) {
      final text = paragraph.trim();
      if (text.isEmpty) continue;
      final block = _measureBlock(
        blocks.length,
        '$readerParagraphIndent$text',
        spec,
      );
      if (block != null) blocks.add(block);
    }
    return ReaderPagination._(
      chapterId: chapterId,
      blocks: blocks,
      pages: _paginate(blocks, spec),
    );
  }

  /// 当前页（或之后第一页）的首段索引，供重排后恢复阅读位置。
  int blockAtPage(int pageIndex) {
    if (pages.isEmpty) return 0;
    final clamped = pageIndex.clamp(0, pages.length - 1).toInt();
    return pages[clamped].firstBlockIndex;
  }

  /// 找到包含 [blockIndex] 的第一页。
  int pageIndexForBlock(int blockIndex) {
    for (var page = 0; page < pages.length; page++) {
      for (final fragment in pages[page].fragments) {
        if (fragment.block.index >= blockIndex) return page;
      }
    }
    return pages.isEmpty ? 0 : pages.length - 1;
  }

  static ReaderBlock? _measureBlock(
    int index,
    String text,
    ReaderLayoutSpec spec,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: spec.bodyStyle),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      textHeightBehavior: readerTextHeightBehavior,
      textWidthBasis: TextWidthBasis.parent,
      locale: const Locale('zh', 'CN'),
    );
    try {
      painter.layout(minWidth: spec.width, maxWidth: spec.width);
      final metrics = painter.computeLineMetrics();
      if (metrics.isEmpty) return null;
      final tops = <double>[];
      final heights = <double>[];
      var top = 0.0;
      for (final line in metrics) {
        tops.add(top);
        heights.add(line.height);
        top += line.height;
      }
      return ReaderBlock(
        index: index,
        text: text,
        // 正常情况两者相等；取较大值保证渲染块的占位高度够裁剪。
        height: math.max(painter.height, top),
        lineTops: tops,
        lineHeights: heights,
      );
    } finally {
      painter.dispose();
    }
  }

  static List<ReaderPage> _paginate(
    List<ReaderBlock> blocks,
    ReaderLayoutSpec spec,
  ) {
    final pages = <ReaderPage>[];
    var fragments = <ReaderFragment>[];
    var used = 0.0;

    void finishPage() {
      if (fragments.isEmpty) return;
      pages.add(ReaderPage(fragments));
      fragments = <ReaderFragment>[];
      used = 0;
    }

    for (final block in blocks) {
      for (var line = 0; line < block.lineCount; line++) {
        final height = block.lineHeights[line];
        // 至少保留一行：即使一行比可读区还高也不能死循环。
        if (fragments.isNotEmpty && used + height > spec.height + _epsilon) {
          finishPage();
        }
        final last = fragments.isEmpty ? null : fragments.last;
        if (last != null && identical(last.block, block)) {
          fragments.removeLast();
          fragments.add(last.extendedTo(line));
        } else {
          fragments.add(
            ReaderFragment(
              block: block,
              firstLine: line,
              lastLine: line,
              top: used,
            ),
          );
        }
        used += height;
      }
      used += spec.paragraphSpacing;
    }
    finishPage();
    return pages;
  }
}
