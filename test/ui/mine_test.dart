import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/category_tab_bar.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/widgets/top_glow.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 我的页预览：统一页头（我的 + 统计 + 设置）+ 小说/短剧两个 tab。
///
/// 更新基线：`flutter test --update-goldens test/ui/mine_test.dart`。
/// 这一页的封面都必须是各自内容类型的原生比例：小说 3:4、短剧 7:10。
void _expectCoverAspect(WidgetTester tester, String label) {
  final bad = tester
      .widgetList<NovelCover>(find.byType(NovelCover))
      .where((cover) {
        final ratio = cover.height / cover.width;
        return (ratio - kNovelCoverAspect).abs() > 0.002 &&
            (ratio - kVideoCoverAspect).abs() > 0.002;
      })
      .map(
        (cover) =>
            '${cover.width.toStringAsFixed(1)}×${cover.height.toStringAsFixed(1)}'
            '(h/w=${(cover.height / cover.width).toStringAsFixed(3)})',
      )
      .toSet();
  expect(bad, isEmpty, reason: '$label 有封面既不是小说 3:4 也不是短剧 7:10：$bad');
}

/// 点 tab 栏里的「小说 / 短剧」切 tab（标签在页头下方的 tabs 行里）。
Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle(const Duration(milliseconds: 400));
}

Map<String, Object> _videoHistoryPrefs() {
  final progress = VideoWatchProgress(
    seriesId: 'v1',
    title: '太奶奶的短剧',
    cover: '',
    episodeIndex: 4,
    updatedAt: DateTime.now(),
  );
  return {
    'video_shelf_v1': jsonEncode([
      VideoSeries(id: 'v1', title: '太奶奶的短剧', episodeCount: 40).toStorageJson(),
      const VideoSeries(
        id: 'v2',
        title: '另一部短剧',
        episodeCount: 12,
      ).toStorageJson(),
    ]),
    'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
    'video_history_v1': jsonEncode([progress.toJson()]),
  };
}

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('我的页-短剧最近观看点击后进播放页', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '太奶奶的短剧',
      episodeIndex: 4,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });
    await pumpPreview(tester, const MinePage());
    await _openTab(tester, '短剧');

    await tester.tap(find.text('看到第 5 集'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoPlayerPage), findsOneWidget);
  });

  testWidgets('我的页（短剧收藏与历史）', (tester) async {
    SharedPreferences.setMockInitialValues(_videoHistoryPrefs());
    await pumpPreview(tester, const MinePage());

    // 页头统计是两边合并的，切 tab 前后都不变。
    expect(find.text('书架 0 本 · 收藏 2 部'), findsOneWidget);

    await _openTab(tester, '短剧');
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('太奶奶的短剧'), findsWidgets);
    expect(find.text('看到第 5 集'), findsOneWidget);
    expect(find.text('另一部短剧'), findsOneWidget);
    // 最近观看和最近阅读同一版式：封面在左、箭头在右。
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsWidgets);
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_drama.png'),
    );
  });

  testWidgets('我的页（空书架）', (tester) async {
    await pumpPreview(tester, const MinePage());
    expect(find.text('我的'), findsOneWidget, reason: '统一页头标题');
    expect(find.text('书架 0 本 · 收藏 0 部'), findsOneWidget);
    expect(find.text('我的书架'), findsOneWidget);
    expect(find.text('书架还是空的，去推荐页看看'), findsOneWidget);
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_empty.png'),
    );
  });

  testWidgets('我的页（有书架与进度）', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        for (var i = 1; i <= 4; i++)
          {
            'id': '$i',
            'title': FakePreviewTransport.titles[i - 1],
            'cover': '',
            'author': '作者$i',
          },
      ]),
      'reading_progress_v1': jsonEncode({
        '1': {
          'bookId': '1',
          'bookTitle': '剑来',
          'cover': '',
          'chapterId': 'c3',
          'chapterIndex': 2,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
      }),
    });
    await pumpPreview(tester, const MinePage());
    expect(find.text('书架 4 本 · 收藏 0 部'), findsOneWidget);
    expect(find.text('最近阅读'), findsOneWidget);
    // 最近阅读（44 宽）和书架卡（_maxCardWidth 内）封面比例也必须统一。
    _expectCoverAspect(tester, '我的页');
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_shelf.png'),
    );
  });

  testWidgets('我的页（短剧空态）', (tester) async {
    await pumpPreview(tester, const MinePage());
    await _openTab(tester, '短剧');
    expect(find.text('还没有观看记录，去推荐页看看短剧'), findsOneWidget);
    expect(find.text('还没有收藏的短剧，去推荐页看看'), findsOneWidget);
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_drama_empty.png'),
    );
  });

  /// tab 之间左右滑动切换（内容完全隔离，各自留着滚动位置）。
  testWidgets('我的页-左右滑动切换 tab', (tester) async {
    await pumpPreview(tester, const MinePage());
    expect(find.text('我的书架'), findsOneWidget);

    await tester.drag(find.byType(TabBarView), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('我的书架'), findsNothing);

    await tester.drag(find.byType(TabBarView), const Offset(300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('我的书架'), findsOneWidget);
    expect(find.text('我的收藏'), findsNothing);
  });

  /// 切走再切回来：保活让每个 tab 的滚动位置各自保留。
  testWidgets('我的页-两个 tab 各自保留滚动位置', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        for (var i = 1; i <= 12; i++)
          {'id': '$i', 'title': '书$i', 'cover': '', 'author': '作者$i'},
      ]),
    });
    await pumpPreview(tester, const MinePage());
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final scrolled = verticalOffset(tester);
    expect(scrolled, greaterThan(100), reason: '前置：书架 tab 已滚离顶部');

    await _openTab(tester, '短剧');
    await _openTab(tester, '小说');
    expect(
      verticalOffset(tester),
      closeTo(scrolled, 0.5),
      reason: '切走再回来滚动位置应保留',
    );
  });

  /// 页头（我的 + 统计 + 设置）与 tabs 固定贴顶，只有 tab 内容滚动。
  testWidgets('我的页-页头固定贴顶不随列表滚动', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        for (var i = 1; i <= 12; i++)
          {'id': '$i', 'title': '书$i', 'cover': '', 'author': '作者$i'},
      ]),
    });
    await pumpPreview(tester, const MinePage());
    final header = find.text('我的');
    final headerBefore = tester.getTopLeft(header);
    final shelfBefore = tester.getTopLeft(find.text('我的书架'));

    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('我的'), findsOneWidget, reason: '页头必须始终可见');
    expect(tester.getTopLeft(header), headerBefore, reason: '页头固定贴顶，不随列表滚动');
    expect(
      tester.getTopLeft(find.text('我的书架')).dy,
      lessThan(shelfBefore.dy),
      reason: '页头下面的书架内容应该正常滚动',
    );
  });

  /// 顶部渐变必须盖住状态栏（安全区）那一条。
  testWidgets('我的页-顶部渐变盖住状态栏', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44);
    await pumpPreview(tester, const MinePage());
    final glow = tester.getRect(find.byType(TopGlow));
    expect(glow.top, 0, reason: '渐变必须从屏幕最顶端开始');
    expect(
      glow.height,
      greaterThanOrEqualTo(150 + 44),
      reason: '高度要包含状态栏安全区，否则顶部会留一条纯白',
    );
  });

  /// 顶部渐变整页统一：小说/短剧 tab 共用同一套，切 tab 不换色带。
  testWidgets('我的页-顶部渐变整页统一', (tester) async {
    await pumpPreview(tester, const MinePage());
    TopGlow glow() => tester.widget<TopGlow>(find.byType(TopGlow));
    expect(glow().spec, same(kMineTopGlow));

    await _openTab(tester, '短剧');
    expect(glow().spec, same(kMineTopGlow), reason: '切到短剧 tab 后渐变不应变化');
  });

  /// tab 样式：无下划线，当前 tab 主题色高亮且字号比未选中大一号。
  testWidgets('我的页-当前 tab 高亮且布局稳定', (tester) async {
    await pumpPreview(tester, const MinePage());
    final scheme = Theme.of(tester.element(find.byType(MinePage))).colorScheme;

    TextStyle styleOf(String label) {
      final finder = find.descendant(
        of: find.byType(CategoryTabBar),
        matching: find.text(label),
      );
      return tester.widget<Text>(finder).style!;
    }

    expect(find.byType(TabBar), findsNothing, reason: '不用带下划线的 TabBar');
    expect(styleOf('小说').color, scheme.primary, reason: '当前 tab 用主题色高亮');
    expect(styleOf('短剧').color, scheme.onSurfaceVariant);
    expect(styleOf('小说').fontSize, CategoryTabBar.selectedFontSize);
    expect(styleOf('短剧').fontSize, CategoryTabBar.fontSize);

    // 两个 tab 的字号不同，但文字都贴在同一条底线上：变大的字只向上长。
    expect(
      tester.getBottomLeft(find.text('小说')).dy,
      tester.getBottomLeft(find.text('短剧')).dy,
      reason: '选中/未选中的文字必须贴同一条底线',
    );

    // 首个 tab 文字左边缘与内容留白（8）对齐，按最大字号预留宽度。
    expect(
      tester.getTopLeft(find.text('小说')).dx,
      closeTo(8, 0.5),
      reason: 'tab 文字应与页头/区块标题左对齐',
    );

    // 固定高度 + 固定占位：切换中/切换后 tab 栏、文字左边缘/底线、内容区
    // 都不挪位置。
    expect(
      tester.getSize(find.byType(CategoryTabBar)).height,
      CategoryTabBar.height,
    );
    final barBefore = tester.getRect(find.byType(CategoryTabBar));
    final novelLeftBefore = tester.getTopLeft(find.text('小说')).dx;
    final dramaLeftBefore = tester.getTopLeft(find.text('短剧')).dx;
    final novelBottomBefore = tester.getBottomLeft(find.text('小说')).dy;
    final dramaBottomBefore = tester.getBottomLeft(find.text('短剧')).dy;
    final bodyBefore = tester.getRect(find.byType(TabBarView));

    await tester.tap(find.text('短剧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byType(CategoryTabBar)), barBefore);
    expect(tester.getTopLeft(find.text('小说')).dx, novelLeftBefore);
    expect(tester.getTopLeft(find.text('短剧')).dx, dramaLeftBefore);
    expect(tester.getBottomLeft(find.text('小说')).dy, novelBottomBefore);
    expect(tester.getBottomLeft(find.text('短剧')).dy, dramaBottomBefore);
    expect(tester.getRect(find.byType(TabBarView)), bodyBefore);

    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(styleOf('短剧').color, scheme.primary);
    expect(styleOf('小说').color, scheme.onSurfaceVariant);
    expect(styleOf('短剧').fontSize, CategoryTabBar.selectedFontSize);
    expect(tester.getRect(find.byType(CategoryTabBar)), barBefore);
    expect(tester.getTopLeft(find.text('小说')).dx, novelLeftBefore);
    expect(tester.getTopLeft(find.text('短剧')).dx, dramaLeftBefore);
    expect(tester.getBottomLeft(find.text('小说')).dy, novelBottomBefore);
    expect(tester.getBottomLeft(find.text('短剧')).dy, dramaBottomBefore);
  });

  /// 拖动 TabBarView 时：未过半仍由原 tab 高亮；一过中线高亮/字号立刻切给
  /// 新 tab（不等松手）。两种状态都是确定的字号，不做逐帧插值。
  testWidgets('我的页-滑动过半才切换 tab 状态', (tester) async {
    await pumpPreview(tester, const MinePage());
    final scheme = Theme.of(tester.element(find.byType(MinePage))).colorScheme;
    TextStyle styleOf(String label) {
      final finder = find.descendant(
        of: find.byType(CategoryTabBar),
        matching: find.text(label),
      );
      return tester.widget<Text>(finder).style!;
    }

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabBarView)),
    );
    // 拖动约 24%：不过半，小说仍然是唯一的选中态。
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-90, 0));
    await tester.pump();
    expect(styleOf('小说').color, scheme.primary);
    expect(styleOf('小说').fontSize, CategoryTabBar.selectedFontSize);
    expect(styleOf('短剧').color, scheme.onSurfaceVariant);
    expect(styleOf('短剧').fontSize, CategoryTabBar.fontSize);

    // 再拖到约 57%：一过中线，高亮和字号一起切给短剧，不等松手。
    await gesture.moveBy(const Offset(-130, 0));
    await tester.pump();
    expect(styleOf('短剧').color, scheme.primary, reason: '过半立即高亮新 tab');
    expect(styleOf('短剧').fontSize, CategoryTabBar.selectedFontSize);
    expect(styleOf('小说').color, scheme.onSurfaceVariant);
    expect(styleOf('小说').fontSize, CategoryTabBar.fontSize);

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });
}
