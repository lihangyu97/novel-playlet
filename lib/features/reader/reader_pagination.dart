import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/chapter_ideas.dart';
import 'reader_bubble.dart';
import 'reader_dialogue.dart';

/// 正文的行高行为。测量（TextPainter）与渲染（Text）必须显式传同一份，
/// 否则两组默认值不同时（比如 DefaultTextStyle 带了 leadingDistribution）
/// 行高会差一两个像素，翻到最后几页就会看到文字被切掉半行。
const TextHeightBehavior readerTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
  leadingDistribution: TextLeadingDistribution.proportional,
);

/// 段落 [TextSpan] 的测量结果：渲染复用同一份 span，缩进宽度也必须一致。
@immutable
class ReaderParagraphSpan {
  const ReaderParagraphSpan({required this.span, required this.placeholders});

  final TextSpan span;

  /// TextPainter 需要显式塞进来的占位尺寸（首行缩进，可能还有段末气泡）；
  /// 渲染时由 RenderParagraph 从 WidgetSpan 子节点算出同样的值
  /// （见 [buildReaderParagraphSpan]）。
  final List<PlaceholderDimensions> placeholders;
}

/// 构造一个段落的 span：首行缩进用零高 WidgetSpan 占位，正文文字仍是干净
/// 的 TextSpan（复制/选区/断行都不被全角空格污染）。
///
/// 测量（TextPainter）与渲染（Text.rich）必须调用同一个函数：缩进宽度与
/// 占位尺寸都由这里算出来，任何一边单独改都会让首行少/多一个字。
ReaderParagraphSpan buildReaderParagraphSpan({
  required String text,
  required TextStyle style,
  required double width,
  required TextScaler textScaler,
  int bubbleCount = 0,
  ParagraphBubbleVariant bubbleVariant = ParagraphBubbleVariant.plain,
  VoidCallback? onBubbleTap,
  bool measureOnly = false,
}) {
  final fontSize = style.fontSize ?? 14;
  // RenderParagraph 会把 WidgetSpan 子节点按周围 span 的字号做自动缩放，
  // 所以这里按"未缩放宽度"给 SizedBox，占位尺寸再乘以 scale。
  final scale = _textScaleFactor(textScaler, fontSize);
  final indent = math.min(
    (fontSize + (style.letterSpacing ?? 0)) * 2,
    math.max(0.0, width / scale - fontSize),
  );
  final children = <InlineSpan>[
    WidgetSpan(
      alignment: PlaceholderAlignment.bottom,
      child: SizedBox(width: indent, height: 0),
    ),
    TextSpan(text: text),
  ];
  final placeholders = <PlaceholderDimensions>[
    PlaceholderDimensions(
      size: Size(indent * scale, 0),
      alignment: PlaceholderAlignment.bottom,
    ),
  ];
  if (bubbleCount > 0) {
    // 段末气泡参与排版：末行宽度要给气泡留位置，否则测量出来的折行与渲染
    // 对不上（气泡会被裁掉或压到文字上）。
    children.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.bottom,
        child: ReaderParagraphBubble(
          count: bubbleCount,
          variant: bubbleVariant,
          onTap: measureOnly ? null : onBubbleTap,
          scaled: !measureOnly,
        ),
      ),
    );
    placeholders.add(
      PlaceholderDimensions(
        size: Size(
          (ReaderParagraphBubble.gap + ReaderParagraphBubble.boxWidth) * scale,
          ReaderParagraphBubble.boxHeight * scale,
        ),
        alignment: PlaceholderAlignment.bottom,
      ),
    );
  }
  return ReaderParagraphSpan(
    span: TextSpan(style: style, children: children),
    placeholders: placeholders,
  );
}

double _textScaleFactor(TextScaler textScaler, double fontSize) {
  if (fontSize <= 0) return 1;
  final factor = textScaler.scale(fontSize) / fontSize;
  if (!factor.isFinite || factor <= 0) return 1;
  return factor;
}

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
/// 分页时只在行边界切页，渲染时把整段 Text.rich 按行偏移裁剪，所以行断点
/// 永远来自同一次 TextPainter 测量，不会因为二次排版而错位。
@immutable
class ReaderBlock {
  ReaderBlock({
    required this.index,
    required this.text,
    required this.height,
    required List<double> lineTops,
    required List<double> lineHeights,
    this.paraIndex,
    this.bubbleCount = 0,
    this.bubbleVariant = ParagraphBubbleVariant.plain,
    List<Rect> dialogueRects = const <Rect>[],
  }) : lineTops = List<double>.unmodifiable(lineTops),
       lineHeights = List<double>.unmodifiable(lineHeights),
       dialogueRects = List<Rect>.unmodifiable(dialogueRects);

  /// 量测缓存命中时直接复用已经算好的行数据与对话矩形，不再拷贝、不再排版。
  const ReaderBlock._reuse({
    required this.index,
    required this.text,
    required this.height,
    required this.lineTops,
    required this.lineHeights,
    this.dialogueRects = const <Rect>[],
    this.paraIndex,
    this.bubbleCount = 0,
    this.bubbleVariant = ParagraphBubbleVariant.plain,
  });

  final int index;
  final String text;
  final double height;
  final List<double> lineTops;
  final List<double> lineHeights;

  /// 对话高亮矩形：段内坐标系，测量时用同一份 TextPainter 的
  /// `getBoxesForSelection` 算好，渲染时只画、不再二次排版。
  final List<Rect> dialogueRects;

  /// 上游段落 id（正文 `<p idx>`），段评气泡与面板按它定位。
  final int? paraIndex;

  /// 本段要画的段评数；0 = 不画气泡。
  final int bubbleCount;
  final ParagraphBubbleVariant bubbleVariant;

  int get lineCount => lineTops.length;
}

/// 段落测量缓存的 key。
///
/// 只有这些输入完全相同时，`TextPainter` 的行位置/高度与对话矩形才可以跨
/// build 复用：段落文本、**段内对话区间**（跨段引号状态会改变它，同一段文字在
/// 不同上下文里高亮范围不同）、气泡（占位参与折行）、以及所有影响字形度量的
/// 排版输入。段间距不影响单段行高，但它是分页输入的一部分，一并纳入避免
/// 以后把段间距改成影响段内边距时漏掉这里。
@immutable
class _BlockMeasureKey {
  const _BlockMeasureKey({
    required this.text,
    required this.dialogueSignature,
    required this.paraIndex,
    required this.bubbleCount,
    required this.bubbleVariant,
    required this.width,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.fontWeight,
    required this.fontFamily,
    required this.scaledFontSize,
    required this.paragraphSpacing,
  });

  final String text;
  final String dialogueSignature;
  final int? paraIndex;
  final int bubbleCount;
  final ParagraphBubbleVariant bubbleVariant;
  final double width;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final FontWeight? fontWeight;
  final String? fontFamily;

  /// 系统字体缩放作用在正文上的实际字号（`TextScaler.scale(fontSize)`）。
  final double scaledFontSize;
  final double paragraphSpacing;

  @override
  bool operator ==(Object other) =>
      other is _BlockMeasureKey &&
      other.text == text &&
      other.dialogueSignature == dialogueSignature &&
      other.paraIndex == paraIndex &&
      other.bubbleCount == bubbleCount &&
      other.bubbleVariant == bubbleVariant &&
      other.width == width &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.letterSpacing == letterSpacing &&
      other.fontWeight == fontWeight &&
      other.fontFamily == fontFamily &&
      other.scaledFontSize == scaledFontSize &&
      other.paragraphSpacing == paragraphSpacing;

  @override
  int get hashCode => Object.hash(
    text,
    dialogueSignature,
    paraIndex,
    bubbleCount,
    bubbleVariant,
    width,
    fontSize,
    lineHeight,
    letterSpacing,
    fontWeight,
    fontFamily,
    scaledFontSize,
    paragraphSpacing,
  );
}

/// 一个段落的测量结果（不含段落下标这类与排版无关的位置信息）。
@immutable
class _MeasuredParagraph {
  const _MeasuredParagraph({
    required this.height,
    required this.lineTops,
    required this.lineHeights,
    required this.dialogueRects,
    required this.effectiveBubbleCount,
  });

  final double height;
  final List<double> lineTops;
  final List<double> lineHeights;
  final List<Rect> dialogueRects;

  /// 实际画出来的气泡数：0 表示末行放不下、这章这一段不画气泡。
  final int effectiveBubbleCount;

  ReaderBlock toBlock({
    required int index,
    required String text,
    required int? paraIndex,
    required ParagraphBubbleVariant bubbleVariant,
  }) => ReaderBlock._reuse(
    index: index,
    text: text,
    height: height,
    lineTops: lineTops,
    lineHeights: lineHeights,
    dialogueRects: dialogueRects,
    paraIndex: paraIndex,
    bubbleCount: effectiveBubbleCount,
    bubbleVariant: bubbleVariant,
  );
}

/// 跨 build 的段落测量 LRU 缓存（默认 512 段）。
///
/// 一次分页会对整章每段跑 TextPainter；字号/宽度/段评计数任一变化都会让整章
/// 重排，但其中绝大多数段落的测量输入并没有变。缓存命中时直接复用行位置、
/// 行高与对话矩形，于是「段评异步到达」的第二遍分页只需要重测真正变化的段
/// （通常只有带气泡的那几段），而不是整章。
class ReaderBlockMeasureCache {
  ReaderBlockMeasureCache({this.capacity = 512}) : assert(capacity > 0);

  final int capacity;

  /// LinkedHashMap 的插入顺序即 LRU 顺序：命中先 remove 再放回队尾。
  final LinkedHashMap<_BlockMeasureKey, _MeasuredParagraph> _entries =
      LinkedHashMap<_BlockMeasureKey, _MeasuredParagraph>();

  int _measureCount = 0;

  /// 实际跑过 TextPainter 的段落数（缓存 miss）。回归测试用它断言第二遍分页
  /// 只测了少量段；生产代码不读。
  @visibleForTesting
  int get measureCount => _measureCount;

  @visibleForTesting
  int get length => _entries.length;

  @visibleForTesting
  void resetMeasureCount() => _measureCount = 0;

  _MeasuredParagraph? _lookup(_BlockMeasureKey key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  void _store(_BlockMeasureKey key, _MeasuredParagraph measured) {
    _entries.remove(key);
    _entries[key] = measured;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void _noteMeasured() => _measureCount++;
}

/// 页内对话区间的签名，用来参与测量缓存 key（跨段引号状态会改变同一段文字
/// 的对话区间，不能只按段落文本缓存）。
String _dialogueSignature(List<TextRange> ranges) {
  if (ranges.isEmpty) return '';
  final buffer = StringBuffer();
  for (final range in ranges) {
    buffer
      ..write(range.start)
      ..write(':')
      ..write(range.end)
      ..write(',');
  }
  return buffer.toString();
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

  /// 仅测试用：整章分页 build 次数（验证「段评到达后不再二次分页」与
  /// 「切章只分页一次」）。
  @visibleForTesting
  static int debugBuildCount = 0;

  /// 仅测试用：最近一次分页实际测量的段落数（验证生产路径确实接上了段落缓存）。
  @visibleForTesting
  static int debugLastMeasuredParagraphs = 0;

  /// 仅测试用：实际计算对话矩形的段落累计次数。关闭「对话高亮」后应为 0 增量
  /// （验证关闭时整章扫描与 `getBoxesForSelection` 都被跳过）。
  @visibleForTesting
  static int debugDialogueMeasureCount = 0;

  @visibleForTesting
  static void debugResetCounters() {
    debugBuildCount = 0;
    debugLastMeasuredParagraphs = 0;
    debugDialogueMeasureCount = 0;
  }

  factory ReaderPagination.build({
    required String chapterId,
    required List<String> paragraphs,
    required ReaderLayoutSpec spec,
    List<int?> paraIndices = const <int?>[],
    bool showBubbles = false,
    Map<int, int> bubbleCounts = const <int, int>{},
    Map<int, ParagraphBubbleVariant> bubbleVariants =
        const <int, ParagraphBubbleVariant>{},
    bool showDialogueHighlight = true,
    ReaderBlockMeasureCache? measureCache,
  }) {
    debugBuildCount++;
    final measuredBefore = measureCache?.measureCount ?? 0;
    final blocks = <ReaderBlock>[];
    // 对话引号可能跨段落开/闭，扫描器按整章顺序保留未闭合状态。
    // 关掉对话高亮时不建扫描器：整章扫描与逐段矩形测量都跳过（仅装饰，不影响断行）。
    final dialogueScanner = showDialogueHighlight
        ? ReaderDialogueScanner()
        : null;
    for (var position = 0; position < paragraphs.length; position++) {
      final text = paragraphs[position].trim();
      if (text.isEmpty) continue;
      final paraIndex = position < paraIndices.length
          ? paraIndices[position]
          : null;
      final bubbleCount = showBubbles && paraIndex != null
          ? bubbleCounts[paraIndex] ?? 0
          : 0;
      final block = _measureBlock(
        blocks.length,
        text,
        spec,
        dialogueScanner: dialogueScanner,
        measureCache: measureCache,
        paraIndex: paraIndex,
        bubbleCount: bubbleCount,
        bubbleVariant: paraIndex == null
            ? ParagraphBubbleVariant.plain
            : bubbleVariants[paraIndex] ?? ParagraphBubbleVariant.plain,
      );
      if (block != null) blocks.add(block);
    }
    debugLastMeasuredParagraphs = measureCache == null
        ? blocks.length
        : measureCache.measureCount - measuredBefore;
    return ReaderPagination._(
      chapterId: chapterId,
      blocks: blocks,
      pages: _paginate(blocks, spec),
    );
  }

  /// 当前页的落点段落下标：优先取本页"开头"的段落（firstLine == 0），
  /// 而不是本页首片段所在段落。
  ///
  /// 段落可能跨页，本页第一行只是上一段的后半截；若存它的下标，恢复时
  /// `pageIndexForBlock` 会把它算到上一页（因为段落从上一页开始）。
  /// 取本页真正开头的段落，才能"读到第几页就回到第几页"。
  /// 整页只有一段的后半截时退回首片段下标（只能回到该段开始处）。
  int blockAtPage(int pageIndex) {
    if (pages.isEmpty) return 0;
    final clamped = pageIndex.clamp(0, pages.length - 1).toInt();
    final fragments = pages[clamped].fragments;
    for (final fragment in fragments) {
      if (fragment.firstLine == 0) return fragment.block.index;
    }
    return fragments.first.block.index;
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

  /// 纯文字排版时最后一行的宽度；用来判断气泡能不能贴在末行。
  static double _lastLineWidth(String text, ReaderLayoutSpec spec) {
    final paragraph = buildReaderParagraphSpan(
      text: text,
      style: spec.bodyStyle,
      width: spec.width,
      textScaler: spec.textScaler,
      measureOnly: true,
    );
    final painter = TextPainter(
      text: paragraph.span,
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      textHeightBehavior: readerTextHeightBehavior,
      textWidthBasis: TextWidthBasis.parent,
      locale: const Locale('zh', 'CN'),
    );
    painter.setPlaceholderDimensions(paragraph.placeholders);
    try {
      painter.layout(minWidth: spec.width, maxWidth: spec.width);
      final metrics = painter.computeLineMetrics();
      return metrics.isEmpty ? 0 : metrics.last.width;
    } finally {
      painter.dispose();
    }
  }

  static ReaderBlock? _measureBlock(
    int index,
    String text,
    ReaderLayoutSpec spec, {
    required ReaderDialogueScanner? dialogueScanner,
    ReaderBlockMeasureCache? measureCache,
    int? paraIndex,
    int bubbleCount = 0,
    ParagraphBubbleVariant bubbleVariant = ParagraphBubbleVariant.plain,
  }) {
    // 先扫对话：即使这一段后面因为排版异常被丢弃，跨段引号状态也要按正文顺序推进。
    // 关闭对话高亮（scanner 为 null）时不扫、不产出矩形。
    final dialogueRanges =
        dialogueScanner?.scanParagraph(text) ?? const <TextRange>[];
    final key = _BlockMeasureKey(
      text: text,
      dialogueSignature: _dialogueSignature(dialogueRanges),
      paraIndex: paraIndex,
      bubbleCount: bubbleCount,
      bubbleVariant: bubbleVariant,
      width: spec.width,
      fontSize: spec.bodyStyle.fontSize ?? 14,
      lineHeight: spec.bodyStyle.height ?? 1,
      letterSpacing: spec.bodyStyle.letterSpacing ?? 0,
      fontWeight: spec.bodyStyle.fontWeight,
      fontFamily: spec.bodyStyle.fontFamily,
      scaledFontSize: spec.textScaler.scale(spec.bodyStyle.fontSize ?? 14),
      paragraphSpacing: spec.paragraphSpacing,
    );
    final cached = measureCache?._lookup(key);
    if (cached != null) {
      return cached.toBlock(
        index: index,
        text: text,
        paraIndex: paraIndex,
        bubbleVariant: bubbleVariant,
      );
    }
    measureCache?._noteMeasured();
    // 气泡是行内元素：只有最后一行还有空间时才能和正文同行。若最后一行正好
    // 占满，气泡必然被挤到下一行独占一行——既难看又容易和下一段错位（Flutter
    // 渲染 widget-only 行时按正文行高算，比占位高度高）。这种段落直接不画
    // 气泡，章节评论入口仍然可用。
    var effectiveBubbleCount = bubbleCount;
    if (bubbleCount > 0) {
      final scale = _textScaleFactor(
        spec.textScaler,
        spec.bodyStyle.fontSize ?? 14,
      );
      final lastLineWidth = _lastLineWidth(text, spec);
      final bubbleTotal =
          (ReaderParagraphBubble.gap + ReaderParagraphBubble.boxWidth) * scale;
      if (lastLineWidth + bubbleTotal > spec.width + _epsilon) {
        effectiveBubbleCount = 0;
      }
    }

    final paragraph = buildReaderParagraphSpan(
      text: text,
      style: spec.bodyStyle,
      width: spec.width,
      textScaler: spec.textScaler,
      bubbleCount: effectiveBubbleCount,
      bubbleVariant: bubbleVariant,
      measureOnly: true,
    );
    final painter = TextPainter(
      text: paragraph.span,
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      textHeightBehavior: readerTextHeightBehavior,
      textWidthBasis: TextWidthBasis.parent,
      locale: const Locale('zh', 'CN'),
    );
    painter.setPlaceholderDimensions(paragraph.placeholders);
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
      // 正常情况两者相等；取较大值保证渲染块的占位高度够裁剪。
      final measured = _MeasuredParagraph(
        height: math.max(painter.height, top),
        lineTops: List<double>.unmodifiable(tops),
        lineHeights: List<double>.unmodifiable(heights),
        // 没有对话区间（含关闭高亮）时保持 const 空表，连矩形计算都不进。
        dialogueRects: dialogueRanges.isEmpty
            ? const <Rect>[]
            : List<Rect>.unmodifiable(_dialogueRects(dialogueRanges, painter)),
        effectiveBubbleCount: effectiveBubbleCount,
      );
      measureCache?._store(key, measured);
      return measured.toBlock(
        index: index,
        text: text,
        paraIndex: paraIndex,
        bubbleVariant: bubbleVariant,
      );
    } finally {
      painter.dispose();
    }
  }

  /// 对话内容在段内的矩形（测量坐标系），供渲染层画荧光笔色带。
  ///
  /// 段落 span 的第一个子节点是首行缩进的 [WidgetSpan]，在文本布局里占 1 个
  /// code unit，所以选区 offset 要整体 +1；气泡是追加在正文之后的 WidgetSpan，
  /// 不影响前置 offset。
  static List<Rect> _dialogueRects(
    List<TextRange> ranges,
    TextPainter painter,
  ) {
    if (ranges.isEmpty) return const <Rect>[];
    debugDialogueMeasureCount++;
    const textOffset = 1;
    final rects = <Rect>[];
    for (final range in ranges) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(
          baseOffset: range.start + textOffset,
          extentOffset: range.end + textOffset,
        ),
      );
      for (final box in boxes) {
        rects.add(box.toRect());
      }
    }
    return _mergeDialogueRects(rects);
  }

  /// 同一行里相邻/嵌套的对话矩形合并成一个，避免圆角色带互相叠出补丁感。
  static List<Rect> _mergeDialogueRects(List<Rect> rects) {
    if (rects.length <= 1) return rects;
    rects.sort((a, b) {
      final byTop = a.top.compareTo(b.top);
      return byTop != 0 ? byTop : a.left.compareTo(b.left);
    });
    final merged = <Rect>[rects.first];
    for (var i = 1; i < rects.length; i++) {
      final rect = rects[i];
      final last = merged.last;
      final sameLine = (rect.top - last.top).abs() < 1;
      if (sameLine && rect.left <= last.right + 2) {
        merged[merged.length - 1] = Rect.fromLTRB(
          last.left,
          math.min(last.top, rect.top),
          math.max(last.right, rect.right),
          math.max(last.bottom, rect.bottom),
        );
      } else {
        merged.add(rect);
      }
    }
    return merged;
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
