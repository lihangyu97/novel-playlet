import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/chapter_ideas.dart';
import 'package:novel_playlet/features/reader/reader_pagination.dart';

/// 段评气泡会改变段末折行，分页测量与渲染必须带同一份气泡占位。
void main() {
  const style = TextStyle(fontSize: 21, height: 1.8);
  const spec = ReaderLayoutSpec(
    width: 320,
    height: 600,
    textScaler: TextScaler.noScaling,
    bodyStyle: style,
    paragraphSpacing: 11.5,
  );

  test('showBubbles 打开后 block 带段落 id 与计数', () {
    final pagination = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: const ['第一段', '第二段'],
      paraIndices: const [5, null],
      showBubbles: true,
      bubbleCounts: const {5: 12},
      bubbleVariants: const {5: ParagraphBubbleVariant.author},
      spec: spec,
    );
    expect(pagination.blocks, hasLength(2));
    expect(pagination.blocks[0].paraIndex, 5);
    expect(pagination.blocks[0].bubbleCount, 12);
    expect(pagination.blocks[0].bubbleVariant, ParagraphBubbleVariant.author);
    expect(pagination.blocks[1].paraIndex, isNull);
    expect(pagination.blocks[1].bubbleCount, 0, reason: '无锚点不画气泡');
  });

  test('showBubbles 关闭时不带气泡，即使有计数', () {
    final pagination = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: const ['第一段'],
      paraIndices: const [5],
      showBubbles: false,
      bubbleCounts: const {5: 12},
      spec: spec,
    );
    expect(pagination.blocks.single.bubbleCount, 0);
    expect(pagination.blocks.single.paraIndex, 5);
  });

  test('span 为气泡多加一个占位（首行缩进 + 气泡）', () {
    final plain = buildReaderParagraphSpan(
      text: '正文',
      style: style,
      width: 320,
      textScaler: TextScaler.noScaling,
    );
    expect(plain.placeholders, hasLength(1));
    expect(plain.span.children, hasLength(2));

    final withBubble = buildReaderParagraphSpan(
      text: '正文',
      style: style,
      width: 320,
      textScaler: TextScaler.noScaling,
      bubbleCount: 8,
    );
    expect(withBubble.placeholders, hasLength(2));
    expect(withBubble.span.children, hasLength(3));
    expect(withBubble.placeholders[1].size.height, greaterThan(0));
  });

  test('长段落加气泡后测量高度不小于不加气泡', () {
    const longText =
        '这是一段用来验证气泡参与排版的正文，长度刚好会折成好几行，'
        '让气泡出现在段末时有机会被挤到下一行。';
    final noBubble = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: const [longText],
      paraIndices: const [3],
      spec: spec,
    );
    final withBubble = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: const [longText],
      paraIndices: const [3],
      showBubbles: true,
      bubbleCounts: const {3: 99},
      spec: spec,
    );
    expect(
      withBubble.blocks.single.lineCount,
      greaterThanOrEqualTo(noBubble.blocks.single.lineCount),
    );
  });

  /// P1-3 回归：段落测量缓存必须把「段内对话区间」算进 key。
  ///
  /// 对话引号可以跨段：同一段文字在「上一段未闭合引号」之后整段都是对话，在
  /// 引号闭合之后则不是。只按段落文本缓存会把前者的高亮矩形复用到后者。
  test('段落测量缓存不把跨段对话矩形串到同文本的其他段', () {
    final cache = ReaderBlockMeasureCache();
    final pagination = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: const ['“第一段还没闭合的对话', '相同的一段文字', '”', '相同的一段文字'],
      spec: spec,
      measureCache: cache,
    );
    expect(pagination.blocks, hasLength(4));
    expect(pagination.blocks[1].text, '相同的一段文字');
    expect(
      pagination.blocks[1].dialogueRects,
      isNotEmpty,
      reason: '这一段处在上一段未闭合的引号里，整段都是对话内容',
    );
    expect(
      pagination.blocks[3].dialogueRects,
      isEmpty,
      reason: '引号已闭合，同文本的段不能复用上一段的对话矩形',
    );
  });

  /// P1-3 回归：段评异步到达后的第二遍分页只重测「输入真的变了」的段。
  ///
  /// 第一遍没有任何段评；第二遍只给 3 段带气泡。修复前第二遍会把整章 40 段
  /// 全部重新 TextPainter 布局；有段落缓存后应只 miss 那 3 段。
  test('段评到达后第二次分页只重测带气泡的少量段', () {
    final cache = ReaderBlockMeasureCache();
    final paragraphs = List<String>.generate(
      40,
      (i) => '第$i段：这是一段用来验证段落测量缓存的正文，长度足够折成好几行。',
    );
    final paraIndices = List<int?>.generate(40, (i) => i);

    ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      paraIndices: paraIndices,
      showBubbles: true,
      spec: spec,
      measureCache: cache,
    );
    expect(cache.measureCount, 40, reason: '首遍没有任何缓存，整章都要量');

    cache.resetMeasureCount();
    ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      paraIndices: paraIndices,
      showBubbles: true,
      bubbleCounts: const {3: 8, 17: 2, 31: 99},
      bubbleVariants: const {17: ParagraphBubbleVariant.author},
      spec: spec,
      measureCache: cache,
    );
    expect(
      cache.measureCount,
      lessThan(paragraphs.length ~/ 4),
      reason: '只有 3 段带气泡需要重测，其余段落应命中缓存',
    );
    expect(cache.measureCount, 3, reason: '缓存命中不应再跑 TextPainter');

    cache.resetMeasureCount();
    ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      paraIndices: paraIndices,
      showBubbles: true,
      bubbleCounts: const {3: 8, 17: 2, 31: 99},
      bubbleVariants: const {17: ParagraphBubbleVariant.author},
      spec: spec,
      measureCache: cache,
    );
    expect(cache.measureCount, 0, reason: '输入完全没变，第三遍应全部命中');
  });

  /// P2 回归：关掉「对话高亮」后，分页跳过整章对话扫描与逐段
  /// `getBoxesForSelection`，但仍要测每段行布局（页数/断行不能变）。
  test('关闭对话高亮时不测量对话矩形', () {
    const paragraphs = ['他说：“走吧，天快黑了。”', '这一段没有对话。', '“第二段对话”后面还有字。'];
    ReaderPagination.debugResetCounters();

    final cold = ReaderBlockMeasureCache();
    final off = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      spec: spec,
      showDialogueHighlight: false,
      measureCache: cold,
    );
    expect(off.blocks.every((block) => block.dialogueRects.isEmpty), isTrue);
    expect(
      ReaderPagination.debugDialogueMeasureCount,
      0,
      reason: '关闭高亮后不应做任何 getBoxesForSelection 测量',
    );
    expect(cold.measureCount, paragraphs.length, reason: '每段仍要测行布局，只是不算对话矩形');

    // 打开高亮：有对话的 2 段要算矩形，证明上面的 0 不是假阴性。
    final onCache = ReaderBlockMeasureCache();
    final on = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      spec: spec,
      showDialogueHighlight: true,
      measureCache: onCache,
    );
    expect(
      on.blocks.where((block) => block.dialogueRects.isNotEmpty),
      hasLength(2),
    );
    expect(ReaderPagination.debugDialogueMeasureCount, 2);

    // 热缓存从「开」切到「关」：无对话段命中缓存，只有 2 段对话要重测
    // （key 里的 dialogue ranges 签名不同），关闭后不再产生新的矩形测量。
    onCache.resetMeasureCount();
    final toggledOff = ReaderPagination.build(
      chapterId: 'c1',
      paragraphs: paragraphs,
      spec: spec,
      showDialogueHighlight: false,
      measureCache: onCache,
    );
    expect(
      toggledOff.blocks.every((block) => block.dialogueRects.isEmpty),
      isTrue,
    );
    expect(onCache.measureCount, 2);
    expect(
      ReaderPagination.debugDialogueMeasureCount,
      2,
      reason: '切到关闭后不应再多算对话矩形',
    );
  });
}
