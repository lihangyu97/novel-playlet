import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/detail/detail_providers.dart';
import 'package:novel_playlet/features/detail/detail_reviews_section.dart';
import 'package:novel_playlet/features/detail/detail_reviews_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 详情页书评卡片与书评弹层：只读展示，不依赖真实网络。
///
/// 书评假数据由 [FakePreviewTransport] 的 `/api/v1/books/{id}/comments`
/// 固定返回（3 条）。更新相关 golden 用
/// `flutter test --update-goldens test/ui/detail_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('详情页书评卡片：只露第一条与「查看全部」', (tester) async {
    await pumpPreview(tester, const DetailPage(bookId: '1'));

    expect(find.text('书评'), findsOneWidget);
    // 标题右侧的现成文案来自接口 context 字段。
    expect(find.text('2.6万人点评'), findsOneWidget);

    // 卡片里只有第一条书评。
    expect(find.text('一蓑烟雨'), findsOneWidget);
    expect(find.textContaining('陈平安的成长线'), findsOneWidget);
    expect(find.text('328'), findsOneWidget);
    expect(find.text('2天前'), findsOneWidget);
    expect(find.text('查看全部 3 条'), findsOneWidget);

    // 其余两条要等弹层才出现。
    expect(find.text('翻书人', skipOffstage: false), findsNothing);
    expect(find.text('剑气长存', skipOffstage: false), findsNothing);

    // score 9 → 4.5 星：4 颗整星 + 1 颗半星（0.5 星粒度）。
    final stars = find.byType(DetailReviewStars);
    final section = find.byType(DetailReviewsSection);
    expect(
      find.descendant(of: section, matching: find.byIcon(Icons.star_rounded)),
      findsNWidgets(4),
    );
    expect(
      find.descendant(
        of: section,
        matching: find.byIcon(Icons.star_half_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: section,
        matching: find.byIcon(Icons.star_border_rounded),
      ),
      findsNothing,
    );
    expect(stars, findsOneWidget);
  });

  testWidgets('点书评卡片：弹层展示全部书评，可滚动阅读并可关闭', (tester) async {
    await pumpPreview(tester, const DetailPage(bookId: '1'));

    await tester.ensureVisible(find.text('查看全部 3 条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看全部 3 条'));
    await tester.pumpAndSettle();

    final sheet = find.byType(DetailReviewsSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('书评')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('共 3 条')),
      findsOneWidget,
    );

    // 全部三条都在弹层里，且正文完整展示（不受卡片 3 行限制）。
    expect(
      find.descendant(of: sheet, matching: find.text('一蓑烟雨')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('翻书人')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('剑气长存')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.textContaining('人物群像')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('关闭书评'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailReviewsSheet), findsNothing);
  });

  testWidgets('没有书评 / 请求失败：卡片保留并显示暂无评论', (tester) async {
    await pumpPreview(
      tester,
      const DetailPage(bookId: '1'),
      extraOverrides: [
        // provider 自身约定失败返回 null，这里直接喂 null 覆盖「接口失败」。
        bookReviewsProvider.overrideWith((ref, bookId) async => null),
      ],
    );

    expect(find.byType(DetailReviewsSection), findsOneWidget);
    expect(find.text('书评'), findsOneWidget);
    expect(find.text('暂无评论'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailReviewsSection),
        matching: find.textContaining('查看全部'),
      ),
      findsNothing,
      reason: '没有书评时不应出现「查看全部」',
    );
    // 详情主内容不受影响。
    expect(find.text('剑来'), findsWidgets);
  });

  testWidgets('书评请求中：卡片先渲染，书评区显示 loading', (tester) async {
    final completer = Completer<BookCommentPage?>();
    await pumpPreview(
      tester,
      const DetailPage(bookId: '1'),
      extraOverrides: [
        bookReviewsProvider.overrideWith((ref, bookId) => completer.future),
      ],
      settle: false,
    );
    // 详情包本身也是异步的：多推几帧让内容淡入；不要 pumpAndSettle，
    // loading 圈会一直动。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DetailReviewsSection), findsOneWidget);
    expect(find.text('书评'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailReviewsSection),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('暂无评论'), findsNothing);

    completer.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('暂无评论'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
