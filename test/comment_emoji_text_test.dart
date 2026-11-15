import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/comment_emoji_text.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/features/detail/detail_reviews_section.dart';

/// 评论正文的方括号表情：只替换官方收录的 token，未知 token 保留原文。
void main() {
  group('commentEmojiSpans', () {
    test('普通文字和已知 token 拆成两个 span', () {
      final spans = commentEmojiSpans('你好[微笑]', fontSize: 16);

      expect(spans, hasLength(2));
      expect((spans[0] as TextSpan).text, '你好');
      final emoji = spans[1] as WidgetSpan;
      expect(emoji.alignment, PlaceholderAlignment.middle);
      final image = emoji.child as Image;
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/emoji/emoji_01.webp',
      );
      expect(image.width, closeTo(22.4, 0.001));
      expect(image.height, closeTo(22.4, 0.001));
    });

    test('未知 token 与前后文字都按原文保留', () {
      final spans = commentEmojiSpans('前[不存在的表情]后', fontSize: 13.5);

      expect(spans, hasLength(3));
      expect((spans[0] as TextSpan).text, '前');
      expect((spans[1] as TextSpan).text, '[不存在的表情]');
      expect((spans[2] as TextSpan).text, '后');
    });

    test('只匹配官方的大小写与中文字符范围', () {
      expect(commentEmojiPattern.hasMatch('[OK]'), isTrue);
      expect(commentEmojiPattern.hasMatch('[书架加一]'), isTrue);
      expect(commentEmojiPattern.hasMatch('[ok]'), isFalse);
      expect(commentEmojiPattern.hasMatch('[微笑'), isFalse);
      expect(commentEmojiPattern.hasMatch('［微笑］'), isFalse);
    });
  });

  testWidgets('53 张表情图都已打进包', (tester) async {
    expect(commentEmojiAssets, hasLength(53));
    expect(commentEmojiAssets.values.toSet(), hasLength(53));

    for (final asset in commentEmojiAssets.values) {
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: asset);
    }
  });

  group('CommentEmojiText', () {
    testWidgets('没有 token 时保持普通 Text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: CommentEmojiText(
              text: '没有表情',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );

      expect(find.text('没有表情'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('有 token 时渲染成内联图片', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: CommentEmojiText(
              text: '[微笑]',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('[微笑]'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('富文本路径透传 maxLines / overflow', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(
              width: 40,
              child: CommentEmojiText(
                text: '[微笑]很长很长的一段话',
                style: TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.byType(Text));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('普通文字路径也透传 maxLines / overflow', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SizedBox(
              width: 40,
              child: CommentEmojiText(
                text: '很长很长的一段话',
                style: TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('很长很长的一段话'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });

  testWidgets('详情页书评行也走表情渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: DetailReviewRow(
            comment: BookComment(id: 'c1', text: '这条[赞]', userName: '读者甲'),
            showStars: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这条[赞]'), findsNothing);
    expect(find.textContaining('[赞]'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
