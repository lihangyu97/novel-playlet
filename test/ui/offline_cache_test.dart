import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_cache_page.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 离线缓存管理页（设置 → 存储 → 离线小说/短剧）的交互测试。
///
/// 不碰真实沙盒：离线存储指向临时目录，统计/列表用 override 注入；只验证
/// 「两个 tab 独立、条目进度、删除/清空走二次确认、超上限提示」这些 UI 契约。
void main() {
  late Directory temp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('offline_cache_ui');
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget buildPage({
    required List<OfflineBookSummary> books,
    required List<OfflineSeriesSummary> series,
    OfflineStats? novelStats,
    OfflineStats? videoStats,
    OfflineTaskKind initialKind = OfflineTaskKind.novel,
  }) {
    return ProviderScope(
      overrides: [
        offlinePathsProvider.overrideWithValue(
          OfflinePaths(rootDirectory: () async => temp),
        ),
        offlineNovelListProvider.overrideWith((ref) async => books),
        offlineVideoListProvider.overrideWith((ref) async => series),
        offlineNovelStatsProvider.overrideWith(
          (ref) async =>
              novelStats ??
              OfflineStats(
                count: books.length,
                bytes: books.fold(0, (sum, book) => sum + book.bytes),
                capBytes: OfflineBookStore.novelCapBytes,
              ),
        ),
        offlineVideoStatsProvider.overrideWith(
          (ref) async =>
              videoStats ??
              OfflineStats(
                count: series.length,
                bytes: series.fold(0, (sum, item) => sum + item.bytes),
                capBytes: OfflineSeriesStore.videoCapBytes,
              ),
        ),
      ],
      child: PreviewApp(home: OfflineCachePage(initialKind: initialKind)),
    );
  }

  final book = OfflineBookSummary(
    bookId: 'b1',
    title: '剑来',
    cover: '',
    completed: 3,
    total: 10,
    bytes: 48 * 1024,
    updatedAt: DateTime.now(),
  );

  final drama = OfflineSeriesSummary(
    seriesId: 's1',
    title: '十八岁太奶奶驾到',
    cover: '',
    completed: 2,
    total: 8,
    bytes: 300 * 1024 * 1024,
    updatedAt: DateTime.now(),
  );

  testWidgets('小说 tab 显示进度/体积，删除走二次确认', (tester) async {
    await tester.pumpWidget(buildPage(books: [book], series: [drama]));
    await tester.pumpAndSettle();

    expect(find.text('剑来'), findsOneWidget);
    expect(find.textContaining('已缓存 3/10 章'), findsOneWidget);
    expect(find.text('继续缓存'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('删除离线缓存？'), findsNothing);
    // 取消后条目仍在。
    expect(find.text('剑来'), findsOneWidget);
  });

  testWidgets('短剧 tab 独立显示，初始落在短剧 tab', (tester) async {
    await tester.pumpWidget(
      buildPage(
        books: [book],
        series: [drama],
        initialKind: OfflineTaskKind.video,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('十八岁太奶奶驾到'), findsOneWidget);
    expect(find.textContaining('已缓存 2/8 集'), findsOneWidget);
    expect(find.text('剑来'), findsNothing);
  });

  testWidgets('清空本区走二次确认，且不影响另一个 tab 的数据', (tester) async {
    await tester.pumpWidget(buildPage(books: [book], series: [drama]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('清空本区'));
    await tester.pumpAndSettle();
    expect(find.text('清空小说离线缓存？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('剑来'), findsOneWidget);
  });

  testWidgets('空态提示去哪里下载', (tester) async {
    await tester.pumpWidget(buildPage(books: [], series: []));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有离线缓存的小说'), findsOneWidget);
    expect(find.text('清空本区'), findsNothing);
  });

  testWidgets('超过本区上限时提示并标红', (tester) async {
    await tester.pumpWidget(
      buildPage(
        books: [book],
        series: [drama],
        novelStats: OfflineStats(
          count: 1,
          bytes: OfflineBookStore.novelCapBytes + 1,
          capBytes: OfflineBookStore.novelCapBytes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已超过本区上限'), findsOneWidget);
  });
}
