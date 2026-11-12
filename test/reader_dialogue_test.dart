import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/reader/reader_dialogue.dart';
import 'package:novel_playlet/features/reader/reader_pagination.dart';

/// 正文对话识别与分页测量得到的荧光笔矩形。
void main() {
  group('findReaderDialogueRanges', () {
    test('只返回引号里的说话内容，引号本身不进区间', () {
      const text = '他说：“走吧。”然后转身。';
      expect(findReaderDialogueRanges(text), const [
        TextRange(start: 4, end: 7),
      ]);
    });

    test('一段里多组对话、兼容「」与『』', () {
      const text = '她问：「你吃了吗？」我答：“吃了。”';
      final ranges = findReaderDialogueRanges(text);
      expect(ranges, const [
        TextRange(start: 4, end: 9),
        TextRange(start: 14, end: 17),
      ]);
    });

    test('嵌套引号按栈配对，内外区间都会产出', () {
      const text = '“他说：「我不知道。」就走了”';
      final ranges = findReaderDialogueRanges(text);
      expect(ranges, hasLength(2));
      expect(ranges.first.start, 5);
      expect(text.substring(ranges.first.start, ranges.first.end), '我不知道。');
      expect(
        text.substring(ranges.last.start, ranges.last.end),
        '他说：「我不知道。」就走了',
      );
    });

    test('未闭合引号与空引号忽略，普通正文返回空', () {
      expect(findReaderDialogueRanges('“没有结尾'), isEmpty);
      expect(findReaderDialogueRanges('没有开头”'), isEmpty);
      expect(findReaderDialogueRanges('“”'), isEmpty);
      expect(findReaderDialogueRanges('这一段没有对话。'), isEmpty);
      expect(findReaderDialogueRanges(''), isEmpty);
    });
  });

  group('分页测量对话矩形', () {
    ReaderLayoutSpec spec() => const ReaderLayoutSpec(
      width: 300,
      height: 600,
      textScaler: TextScaler.noScaling,
      bodyStyle: TextStyle(fontSize: 18, height: 1.6),
      paragraphSpacing: 9,
    );

    test('有对话的段才有矩形，且落在段宽内', () {
      final pagination = ReaderPagination.build(
        chapterId: 'c1',
        paragraphs: const ['“你来了。”他说。', '这一段没有对话。', '「好」'],
        spec: spec(),
      );
      expect(pagination.blocks, hasLength(3));
      final withDialogue = pagination.blocks[0];
      expect(withDialogue.dialogueRects, isNotEmpty);
      expect(pagination.blocks[1].dialogueRects, isEmpty);
      expect(pagination.blocks[2].dialogueRects, isNotEmpty);
      for (final rect in withDialogue.dialogueRects) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(300 + 1));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(withDialogue.height));
      }
    });

    test('跨行对话每一行都有一段矩形', () {
      final longDialogue = '“${'这是一段很长的对话内容，' * 8}”';
      final pagination = ReaderPagination.build(
        chapterId: 'c1',
        paragraphs: [longDialogue],
        spec: spec(),
      );
      final block = pagination.blocks.single;
      expect(block.lineCount, greaterThan(1));
      expect(block.dialogueRects.length, greaterThan(1));
    });
  });
}
