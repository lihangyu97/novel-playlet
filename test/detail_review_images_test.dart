import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/comment_image_loader.dart';
import 'package:novel_playlet/app/widgets/comment_image_strip.dart';
import 'package:novel_playlet/app/widgets/comment_image_viewer.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/features/detail/detail_reviews_section.dart';

import 'test_images.dart';

void main() {
  testWidgets('书评行渲染配图，点缩略图打开全屏查看器', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentImageLoaderProvider.overrideWithValue(fakeCommentImageLoader),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: DetailReviewRow(
                comment: BookComment(
                  id: 'c1',
                  userName: '读者甲',
                  text: '这本书的配图书评',
                  imageUrls: const [
                    'https://example.com/a.jpg',
                    'https://example.com/b.jpg',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这本书的配图书评'), findsOneWidget);
    expect(find.byType(CommentImageStrip), findsOneWidget);

    await tester.tap(find.byType(Image).first);
    // 全屏页里的图片加载占位是转圈动画：不能 pumpAndSettle，否则永远转。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CommentImageViewer), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget, reason: '点第一张从第一张开始看');
  });

  testWidgets('超过 9 张只画 9 张，最后一张盖 +N', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentImageLoaderProvider.overrideWithValue(fakeCommentImageLoader),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: CommentImageStrip(
                  imageUrls: [
                    for (var i = 0; i < 12; i++) 'https://example.com/$i.jpg',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNWidgets(CommentImageStrip.maxImages));
    expect(find.text('+3'), findsOneWidget);

    // 点第 9 张（`+3` 那张）仍然从第 9 张开始，而不是丢掉后面的图。
    await tester.tap(find.text('+3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('9 / 12'), findsOneWidget);
  });
}
