import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/app_snack_bar.dart';

/// 全站轻提示统一 1 秒：SnackBar 默认 4s 挂太久，连续操作还会排队。
void main() {
  testWidgets('默认 1 秒后消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSnackBar(context, '已收藏'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    expect(find.text('已收藏'), findsOneWidget);

    // 0.5s 时还在（确认不是立刻消失）。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('已收藏'), findsOneWidget);

    // 1s 出头 + 退场动画后应完全消失（进场动画约 250ms，1s 从进场完成算起）。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已收藏'), findsNothing);
  });

  testWidgets('连续提示只保留最新一条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showAppSnackBar(context, '第一条');
                showAppSnackBar(context, '第二条');
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第一条'), findsNothing);
  });

  test('统一时长就是 1s', () {
    expect(appSnackBarDuration, const Duration(seconds: 1));
  });
}
