import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/diagnostics/diagnostic_log.dart';
import 'package:novel_playlet/features/logs/app_log_page.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';

import 'preview_harness.dart';

DiagnosticEntry _entry({
  LogLevel level = LogLevel.error,
  DiagnosticSource source = DiagnosticSource.api,
  String message = 'GET /api/v1/feed 失败：网络超时，请重试',
  String? detail,
  int count = 1,
}) {
  return DiagnosticEntry(
    at: DateTime.now().millisecondsSinceEpoch,
    level: level,
    source: source,
    message: message,
    detail: detail,
    count: count,
  );
}

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  testWidgets('运行日志页：报错行 + 展开上下文', (tester) async {
    final entry = _entry(
      detail: 'HTTP 504\nkind=timeout\n耗时 20000ms',
      count: 3,
    );

    await pumpPreview(
      tester,
      const AppLogPage(),
      extraOverrides: [
        diagnosticLogEntriesProvider.overrideWith((ref) async => [entry]),
      ],
    );

    expect(find.text('今天'), findsOneWidget);
    expect(find.textContaining('/api/v1/feed'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    expect(find.textContaining('HTTP 504'), findsNothing, reason: '默认收起');

    await tester.tap(find.textContaining('/api/v1/feed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTP 504'), findsOneWidget);
    expect(find.textContaining('接口 · 报错'), findsOneWidget);
  });

  testWidgets('运行日志页：意外事件用另一套文案', (tester) async {
    final entry = _entry(
      level: LogLevel.unexpected,
      source: DiagnosticSource.app,
      message: '推荐返回的分类不匹配',
      detail: '期望 tab_type=8，实际=2',
    );

    await pumpPreview(
      tester,
      const AppLogPage(),
      extraOverrides: [
        diagnosticLogEntriesProvider.overrideWith((ref) async => [entry]),
      ],
    );

    expect(find.text('推荐返回的分类不匹配'), findsOneWidget);
    await tester.tap(find.text('推荐返回的分类不匹配'));
    await tester.pumpAndSettle();
    expect(find.textContaining('应用 · 意外'), findsOneWidget);
    expect(find.textContaining('期望 tab_type=8'), findsOneWidget);
  });

  testWidgets('运行日志页：空态', (tester) async {
    await pumpPreview(
      tester,
      const AppLogPage(),
      extraOverrides: [
        diagnosticLogEntriesProvider.overrideWith(
          (ref) async => const <DiagnosticEntry>[],
        ),
      ],
    );

    expect(find.text('还没有日志'), findsOneWidget);
  });

  testWidgets('设置页诊断入口打开运行日志', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      extraOverrides: [
        diagnosticLogEntriesProvider.overrideWith(
          (ref) async => const <DiagnosticEntry>[],
        ),
      ],
    );

    final entryFinder = find.byKey(diagnosticsLogEntryKey);
    await tester.scrollUntilVisible(
      entryFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(entryFinder);
    await tester.pumpAndSettle();

    expect(find.byType(AppLogPage), findsOneWidget);
    expect(find.text('还没有日志'), findsOneWidget);
  });
}
