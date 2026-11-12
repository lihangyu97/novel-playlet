import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/reader/reader_dialogue.dart';
import 'package:novel_playlet/features/reader/reader_pagination.dart';
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:novel_playlet/features/reader/reader_widgets.dart';

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

    test('嵌套引号合并成一段说话内容', () {
      const text = '“他说：「我不知道。」就走了”';
      final ranges = findReaderDialogueRanges(text);
      expect(ranges, hasLength(1), reason: '内层引号属于外层说话内容，合并成一段');
      expect(
        text.substring(ranges.single.start, ranges.single.end),
        '他说：「我不知道。」就走了',
      );
    });

    test('孤立右引号/空引号忽略，未闭合左引号延续到段尾', () {
      // 未闭合左引号不再丢弃：真实源里它会在后面的段落闭合，单段调用按
      // 「从引号后到段尾都算说话内容」返回。
      expect(findReaderDialogueRanges('“没有结尾'), const [
        TextRange(start: 1, end: 5),
      ]);
      expect(findReaderDialogueRanges('没有开头”'), isEmpty);
      expect(findReaderDialogueRanges('“”'), isEmpty);
      expect(findReaderDialogueRanges('这一段没有对话。'), isEmpty);
      expect(findReaderDialogueRanges(''), isEmpty);
    });
  });

  group('ReaderDialogueScanner 跨段', () {
    test('左引号在本段、右引号在下一段：两段都识别为对话', () {
      final scanner = ReaderDialogueScanner();
      expect(scanner.scanParagraph('他说：“你先'), const [
        TextRange(start: 4, end: 6),
      ]);
      expect(scanner.scanParagraph('别急着走。”他转身离开。'), const [
        TextRange(start: 0, end: 5),
      ]);
      expect(scanner.scanParagraph('这一句是旁白。'), isEmpty);
    });

    test('多段引语每段重复左引号、最后一段才闭合', () {
      final scanner = ReaderDialogueScanner();
      expect(scanner.scanParagraph('“第一段'), const [
        TextRange(start: 1, end: 4),
      ]);
      expect(scanner.scanParagraph('“第二段'), const [
        TextRange(start: 1, end: 4),
      ]);
      expect(scanner.scanParagraph('“第三段”'), const [
        TextRange(start: 1, end: 4),
      ]);
      expect(scanner.scanParagraph('旁白。'), isEmpty);
    });

    test('空段不打断跨段状态', () {
      final scanner = ReaderDialogueScanner();
      expect(scanner.scanParagraph('“前半'), hasLength(1));
      expect(scanner.scanParagraph(''), isEmpty);
      expect(scanner.scanParagraph('后半”'), const [TextRange(start: 0, end: 2)]);
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

    testWidgets('开关与颜色都作用到对话色带', (tester) async {
      final pagination = ReaderPagination.build(
        chapterId: 'c1',
        paragraphs: const ['“你来了。”他说。'],
        spec: spec(),
      );
      const textStyle = TextStyle(fontSize: 18, height: 1.6);
      Widget build({
        required bool enabled,
        Color color = ReaderSettings.defaultDialogueHighlightColor,
      }) => MaterialApp(
        home: Scaffold(
          body: ReaderPageContent(
            page: pagination.pages.first,
            textStyle: textStyle,
            textScaler: TextScaler.noScaling,
            contentWidth: 300,
            horizontalPadding: 20,
            showDialogueHighlight: enabled,
            dialogueHighlightColor: color,
          ),
        ),
      );

      await tester.pumpWidget(build(enabled: true));
      final highlighter = find.byKey(
        const ValueKey('reader-dialogue-highlight'),
      );
      expect(highlighter, findsOneWidget);
      Color? painterColor() {
        final painter = tester.widget<CustomPaint>(highlighter).painter;
        return (painter as dynamic).color as Color?;
      }

      expect(
        painterColor(),
        ReaderSettings.defaultDialogueHighlightColor.withValues(alpha: 0.34),
      );

      // 设置页改了荧光笔颜色后，色带颜色必须真的跟着变（曾经预览恒为黄）。
      const picked = Color(0xFF66BB6A);
      await tester.pumpWidget(build(enabled: true, color: picked));
      expect(painterColor(), picked.withValues(alpha: 0.34));

      await tester.pumpWidget(build(enabled: false, color: picked));
      expect(highlighter, findsNothing);
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
