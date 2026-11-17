import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/sync_log_page.dart';

import 'preview_harness.dart';

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  testWidgets('同步记录页：结果行 + 展开明细', (tester) async {
    final run = SyncLogRun(
      at: DateTime.now().millisecondsSinceEpoch,
      durationMs: 840,
      outcome: SyncOutcome.success,
      trigger: SyncTrigger.lifecycle,
      revBefore: 12,
      revAfter: 15,
      uploaded: true,
      remoteUpdatedAt: DateTime.now().millisecondsSinceEpoch - 60000,
      pushedTotal: 1,
      pushed: const [
        SyncLogChange(
          key: 'novel/a',
          type: LibraryType.novel,
          title: '剑来',
          fields: [
            SyncLogField(
              field: 'progress',
              before: '第 12 章 · 第 3 段',
              after: '第 15 章 · 第 1 段',
            ),
          ],
        ),
      ],
    );

    await pumpPreview(
      tester,
      const SyncLogPage(),
      extraOverrides: [
        syncLogRunsProvider.overrideWith((ref) async => [run]),
      ],
    );

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('↑1'), findsOneWidget);
    expect(find.text('r12 → r15'), findsOneWidget);
    expect(find.textContaining('840ms'), findsOneWidget);

    await tester.tap(find.text('↑1'));
    await tester.pumpAndSettle();
    expect(find.text('上传到云端（1）'), findsOneWidget);
    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('进度：第 12 章 · 第 3 段 → 第 15 章 · 第 1 段'), findsOneWidget);
  });

  testWidgets('同步记录页：失败行显示错误文案与阶段', (tester) async {
    final run = SyncLogRun(
      at: DateTime.now().millisecondsSinceEpoch,
      durationMs: 300,
      outcome: SyncOutcome.failed,
      trigger: SyncTrigger.manual,
      phase: 'get',
      error: '下载同步文件失败：账号或应用密码错误',
    );

    await pumpPreview(
      tester,
      const SyncLogPage(),
      extraOverrides: [
        syncLogRunsProvider.overrideWith((ref) async => [run]),
      ],
    );

    expect(find.text('拉取失败'), findsOneWidget);
    expect(find.text('下载同步文件失败：账号或应用密码错误'), findsOneWidget);
  });

  testWidgets('同步记录页：空态', (tester) async {
    await pumpPreview(
      tester,
      const SyncLogPage(),
      extraOverrides: [
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );
    expect(find.text('还没有同步记录'), findsOneWidget);
  });
}
