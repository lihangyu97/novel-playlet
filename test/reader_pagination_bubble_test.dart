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
}
