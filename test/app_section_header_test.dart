import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/app_section_header.dart';

/// `AppSectionHeader` 的标题后缀（条数）必须贴着标题，右侧操作仍然贴右。
void main() {
  testWidgets('titleSuffix 紧跟标题，trailing 仍靠右', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppSectionHeader(
            title: '收藏',
            titleSuffix: Text('8 条'),
            trailing: Icon(Icons.chevron_right_rounded),
          ),
        ),
      ),
    );

    final title = tester.getRect(find.text('收藏'));
    final suffix = tester.getRect(find.text('8 条'));
    final trailing = tester.getRect(find.byIcon(Icons.chevron_right_rounded));

    expect(
      suffix.left - title.right,
      lessThanOrEqualTo(8),
      reason: '条数与标题之间只留 6pt，不能跟着右侧操作一起被推远',
    );
    expect(trailing.left, greaterThan(suffix.right), reason: '右侧操作仍占最右槽位');
  });
}
