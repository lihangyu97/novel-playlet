import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/mine/widgets/library_type_badge.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';

import 'preview_harness.dart';

/// 我的页：历史 + 收藏（小说与短剧混排）。
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
    expect(find.text('历史 0 · 收藏 0'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('还没有阅读记录，去推荐页逛逛'), findsOneWidget);
    expect(find.text('收藏夹还是空的，去推荐页看看'), findsOneWidget);

    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_empty.png'),
    );
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

    // 短剧条目点进去直接进播放页（续播到第 5 集）。
    await tester.tap(find.text('看到第 5 集'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoPlayerPage), findsOneWidget);
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

  testWidgets('我的页-页头固定贴顶不随列表滚动', (tester) async {
    final store = ReadingStore();
    for (var i = 12; i >= 1; i--) {
      await store.addToShelf(
        NovelItem(id: 'b$i', title: '书$i', author: '作者$i'),
      );
    }

    await pumpPreview(tester, const MinePage(), store: store);

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
