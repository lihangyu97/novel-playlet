import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/mine/widgets/library_type_badge.dart';
import 'package:novel_playlet/features/mine/widgets/mine_all_sheet.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';

import 'preview_harness.dart';

/// 我的页：在看 + 收藏 + 历史（小说与短剧混排）。
///
/// 更新基线：`flutter test --update-goldens test/ui/mine_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  /// 收藏网格覆盖统一按小说 3:4 出图（短剧封面裁切），同一行高度一致。
  void expectUnifiedCoverAspect(WidgetTester tester) {
    final covers = tester.widgetList<NovelCover>(find.byType(NovelCover));
    final bad = covers
        .where(
          (cover) =>
              (cover.height / cover.width - kNovelCoverAspect).abs() > 0.002,
        )
        .map((c) => '${c.width}×${c.height}')
        .toSet();
    expect(bad, isEmpty, reason: '收藏混排必须统一 3:4：$bad');
  }

  testWidgets('我的页-空态', (tester) async {
    await pumpPreview(tester, const MinePage());

    expect(find.text('我的'), findsOneWidget, reason: '统一页头标题');
    expect(find.text('在看'), findsNothing, reason: '没有 pin 时整块隐藏');
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('0 条'), findsNWidgets(2), reason: '两个区块头都显示条数');
    expect(find.byKey(MinePage.historyAllKey), findsNothing);
    expect(find.byKey(MinePage.collectionAllKey), findsNothing);
    expect(find.text('还没有阅读记录，去推荐页逛逛'), findsOneWidget);
    expect(find.text('收藏夹还是空的，去推荐页看看'), findsOneWidget);

    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_empty.png'),
    );
  });

  testWidgets('标签：视觉单字「书 / 剧」，读屏仍念「小说 / 短剧」', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                LibraryTypeBadge(type: LibraryType.novel),
                LibraryTypeBadge(type: LibraryType.playlet, dense: true),
              ],
            ),
          ),
        ),
      );
      expect(find.text('书'), findsOneWidget);
      expect(find.text('剧'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(LibraryTypeBadge).first).label,
        '小说',
      );
      expect(
        tester.getSemantics(find.byType(LibraryTypeBadge).last).label,
        '短剧',
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('我的页-历史混排：标签区分类型，短剧点击直接续播', (tester) async {
    final store = ReadingStore();
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '剑来',
      cover: '',
      chapterId: 'c3',
      chapterIndex: 2,
    );
    await store.saveVideoProgress(
      seriesId: 'p1',
      title: '太奶奶的短剧',
      episodeIndex: 4,
    );

    await pumpPreview(tester, const MinePage(), store: store);

    // 一条时间线：后看的短剧排在前面，两种类型都在。
    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('太奶奶的短剧'), findsOneWidget);
    expect(find.text('读到第 3 章'), findsOneWidget);
    expect(find.text('看到第 5 集'), findsOneWidget);

    // 副标题前的彩色标签。
    final badges = tester.widgetList<LibraryTypeBadge>(
      find.byType(LibraryTypeBadge),
    );
    expect(badges, hasLength(2));
    expect(badges.where((b) => b.type.isPlaylet), hasLength(1));
    // 历史行的标签与收藏封面同尺寸（标准 15pt），不要为了塞进副标题行缩小。
    expect(badges.every((b) => !b.dense), isTrue);
    expect(
      tester.getSize(find.byType(LibraryTypeBadge).first).height,
      15,
      reason: '历史行标签高度与收藏封面标签一致',
    );

    // 短剧条目点进去直接进播放页（续播到第 5 集）。
    await tester.tap(find.text('看到第 5 集'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoPlayerPage), findsOneWidget);
  });

  testWidgets('我的页-在看：一排卡片、区块顺序在看/收藏/历史', (tester) async {
    final store = ReadingStore();
    await store.saveProgress(
      bookId: 'n1',
      bookTitle: '剑来',
      cover: '',
      chapterId: 'c3',
      chapterIndex: 2,
    );
    await store.togglePin(type: LibraryType.novel, sourceId: 'n1', title: '剑来');
    await store.saveVideoProgress(
      seriesId: 'p1',
      title: '太奶奶的短剧',
      episodeIndex: 4,
    );
    await store.togglePin(
      type: LibraryType.playlet,
      sourceId: 'p1',
      title: '太奶奶的短剧',
    );

    await pumpPreview(tester, const MinePage(), store: store);

    expect(find.text('在看'), findsOneWidget);
    expect(find.text('读到第 3 章'), findsNWidgets(2), reason: '在看卡片 + 历史行');

    // 页面顺序：在看 → 收藏 → 历史。
    final pinTop = tester.getTopLeft(find.byKey(MinePage.pinKey)).dy;
    final collectionTop = tester
        .getTopLeft(find.byKey(MinePage.collectionKey))
        .dy;
    final historyTop = tester.getTopLeft(find.byKey(MinePage.historyKey)).dy;
    expect(pinTop, lessThan(collectionTop));
    expect(collectionTop, lessThan(historyTop));

    // 全量弹窗能看到两条在看，并可直接取消。
    await tester.tap(find.byKey(MinePage.pinAllKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byKey(mineAllSheetKey), findsOneWidget);
    expect(find.text('全部在看'), findsOneWidget);
    expect(find.text('共 2 条'), findsOneWidget);
  });

  testWidgets('我的页-收藏混排：统一 3:4 封面 + 标签 + 长按移出', (tester) async {
    final store = ReadingStore();
    await store.addToShelf(
      const NovelItem(id: 'n1', title: '剑来', author: '烽火戏诸侯'),
    );
    await store.addVideoToShelf(
      const VideoSeries(id: 'p1', title: '太奶奶的短剧', episodeCount: 40),
    );

    await pumpPreview(tester, const MinePage(), store: store);

    expect(find.text('剑来'), findsOneWidget);
    expect(find.text('烽火戏诸侯'), findsOneWidget);
    expect(find.text('太奶奶的短剧'), findsOneWidget);
    expect(find.text('全 40 集'), findsOneWidget);
    expectUnifiedCoverAspect(tester);

    // 收藏卡的左上角标签。
    expect(
      find.descendant(
        of: find.byType(MinePage),
        matching: find.byType(LibraryTypeBadge),
      ),
      findsNWidgets(2),
    );

    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_shelf.png'),
    );

    await tester.longPress(find.text('剑来'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.tap(find.text('移出书架'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.text('剑来'), findsNothing, reason: '移出后收藏里不该再有它');
    expect(find.text('太奶奶的短剧'), findsOneWidget);
  });

  testWidgets('我的页-收藏预览最多 6 个，全部弹窗列表可左滑移出', (tester) async {
    final store = ReadingStore();
    for (var i = 1; i <= 8; i++) {
      await store.addToShelf(
        NovelItem(id: 'b$i', title: '书$i', author: '作者$i'),
      );
    }

    await pumpPreview(tester, const MinePage(), store: store);

    // 预览只铺最新 6 个（3 列正好两排），更早的条目只在全部弹窗里。
    expect(find.text('书8'), findsOneWidget);
    expect(find.text('书3'), findsOneWidget);
    expect(find.text('书2'), findsNothing);
    expect(find.text('书1'), findsNothing);
    expect(find.text('8 条'), findsOneWidget);

    await tester.tap(find.byKey(MinePage.collectionAllKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.byKey(mineAllSheetKey), findsOneWidget);
    expect(find.text('全部收藏'), findsOneWidget);
    expect(find.text('共 8 条'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(mineAllSheetKey),
        matching: find.text('书1'),
      ),
      findsOneWidget,
      reason: '全部弹窗要能看到预览外的收藏',
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/mine_all_sheet.png'),
    );

    await tester.drag(
      find.descendant(
        of: find.byKey(mineAllSheetKey),
        matching: find.text('书1'),
      ),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('移出收藏？'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('移出收藏'),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(
      find.descendant(
        of: find.byKey(mineAllSheetKey),
        matching: find.text('书1'),
      ),
      findsNothing,
    );
    expect(find.text('共 7 条'), findsOneWidget);
    expect(await store.shelfCount(), 7);
  });

  testWidgets('我的页-全部历史左滑删除只清进度，收藏保留', (tester) async {
    final store = ReadingStore();
    await store.addToShelf(
      const NovelItem(id: 'n1', title: '收藏中的历史', author: '作者'),
    );
    for (var i = 1; i <= 5; i++) {
      await store.saveProgress(
        bookId: 'n$i',
        bookTitle: i == 1 ? '收藏中的历史' : '历史$i',
        cover: '',
        chapterId: 'c$i',
        chapterIndex: i,
      );
    }

    await pumpPreview(tester, const MinePage(), store: store);

    // 页面上历史只露最新 3 条。
    expect(find.text('历史5'), findsOneWidget);
    expect(find.text('历史3'), findsOneWidget);
    expect(find.text('历史2'), findsNothing);

    await tester.tap(find.byKey(MinePage.historyAllKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    expect(find.text('全部历史'), findsOneWidget);
    expect(find.text('共 5 条'), findsOneWidget);
    final sheetItem = find.descendant(
      of: find.byKey(mineAllSheetKey),
      matching: find.text('收藏中的历史'),
    );
    expect(sheetItem, findsOneWidget);

    await tester.drag(sheetItem, const Offset(-500, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('删除这条历史？'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(sheetItem, findsNothing);
    expect(find.text('共 4 条'), findsOneWidget);
    expect(await store.historyCount(), 4);
    expect(await store.progress('n1'), isNull);
    expect(await store.isOnShelf('n1'), isTrue, reason: '删历史不能把收藏一起删掉');
    expect(find.text('收藏中的历史'), findsOneWidget, reason: '页面上的收藏卡仍在');
  });

  testWidgets('我的页-收藏里的短剧把标题里的季标在封面左下角', (tester) async {
    final store = ReadingStore();
    await store.addVideoToShelf(
      const VideoSeries(id: 'p7', title: '反差大佬：我家小师妹超正经第七季', episodeCount: 177),
    );
    // 小说标题里就算出现「第 N 季」字样也不加季角标：季角标只属于短剧。
    await store.addToShelf(
      const NovelItem(id: 'n1', title: '第二季的雨', author: '作者'),
    );

    await pumpPreview(tester, const MinePage(), store: store);

    // 精确位置由 video_card_test 断言（这里只验证收藏卡也接上了季角标）。
    expect(find.text('第7季'), findsOneWidget);
    expect(find.text('第2季'), findsNothing, reason: '小说卡不显示季角标');
  });

  testWidgets('我的页-页头固定贴顶不随列表滚动', (tester) async {
    final store = ReadingStore();
    for (var i = 12; i >= 1; i--) {
      await store.addToShelf(
        NovelItem(id: 'b$i', title: '书$i', author: '作者$i'),
      );
    }

    await pumpPreview(tester, const MinePage(), store: store);
    // 预览条数有上限（收藏最多 6 个），正常手机高度下整页可能已经放得下；
    // 这里把窗口压矮，验证固定页头与可滚动内容是分开的两层。
    tester.view.physicalSize = const Size(390, 620);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    final header = find.text('我的');
    final headerBefore = tester.getTopLeft(header);
    final sectionBefore = tester.getTopLeft(find.text('收藏'));

    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('我的'), findsOneWidget, reason: '页头必须始终可见');
    expect(tester.getTopLeft(header), headerBefore, reason: '页头固定贴顶');
    expect(
      tester.getTopLeft(find.text('收藏')).dy,
      lessThan(sectionBefore.dy),
      reason: '页头下面的内容应该正常滚动',
    );
  });
}
