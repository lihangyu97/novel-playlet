import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/widgets/top_glow.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 我的页预览：小说/短剧双面板、悬浮切换、书架与最近观看。
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
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    await tester.tap(find.text('看到第 5 集'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoPlayerPage), findsOneWidget);
  });

  testWidgets('我的页（短剧收藏与历史）', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '太奶奶的短剧',
      cover: '',
      episodeIndex: 4,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_shelf_v1': jsonEncode([
        VideoSeries(
          id: 'v1',
          title: '太奶奶的短剧',
          episodeCount: 40,
        ).toStorageJson(),
        const VideoSeries(
          id: 'v2',
          title: '另一部短剧',
          episodeCount: 12,
        ).toStorageJson(),
      ]),
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });

    await pumpPreview(tester, const MinePage());
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.text('最近观看 1 条 · 收藏 2 部'), findsOneWidget);
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
    // 最近阅读（44 宽）和书架卡（_maxCardWidth 内）封面比例也必须统一。
    _expectCoverAspect(tester, '我的页');
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_shelf.png'),
    );
  });

  /// 悬浮按钮切换：小说面板滑出、短剧滑入，按钮图标同时换成另一侧。
  testWidgets('我的页-悬浮按钮切到短剧', (tester) async {
    await pumpPreview(tester, const MinePage());

    // 初始：小说在屏幕内，按钮显示「短剧」图标（点它去看短剧）。
    expect(find.text('小说'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.theaters_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.text('短剧'), findsWidgets);
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    // 短剧标题块（延迟 0）已就位；小说标题整块滑到屏幕左侧外。
    expect(
      tester.getTopRight(find.text('短剧')).dx,
      closeTo(338, 1),
      reason: '短剧标题应停在镜像位置',
    );
    expect(tester.getTopLeft(find.text('小说')).dx, lessThan(-300));
    // 按钮换成「小说」图标。
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.auto_stories_rounded),
      ),
      findsOneWidget,
    );

    // 再点回小说。
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopLeft(find.text('小说')).dx, closeTo(52, 1));
    expect(find.text('我的书架'), findsOneWidget);
  });

  /// 左右滑动也能切换（类似阅读器翻页），不依赖悬浮按钮。
  testWidgets('我的页-左右滑动切换面板', (tester) async {
    await pumpPreview(tester, const MinePage());

    // 往左滑 → 短剧。
    await tester.drag(find.byType(MinePage), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopRight(find.text('短剧')).dx, closeTo(338, 1));
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.auto_stories_rounded),
      ),
      findsOneWidget,
    );

    // 往右滑 → 回小说。
    await tester.drag(find.byType(MinePage), const Offset(300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopLeft(find.text('小说')).dx, closeTo(52, 1));
  });

  /// 过渡不是整页一起动：标题块 0ms 先走，最近阅读块晚 100ms，书架块晚 200ms。
  testWidgets('我的页-三块阶梯延迟切换', (tester) async {
    // 需要有最近阅读内容，才能观察中间块（0ms）比标题块（100ms）先动。
    SharedPreferences.setMockInitialValues({
      'recent_reading_v1': jsonEncode([
        {
          'bookId': '1',
          'bookTitle': '剑来',
          'cover': '',
          'chapterId': 'c3',
          'chapterIndex': 2,
          'blockIndex': 0,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    });
    await pumpPreview(tester, const MinePage());
    final headerBefore = tester.getTopLeft(find.text('小说')).dx;
    final recentBefore = tester.getTopLeft(find.text('最近阅读')).dx;
    final shelfBefore = tester.getTopLeft(find.text('我的书架')).dx;

    final gesture = await tester.startGesture(const Offset(200, 500));
    // 吃掉触摸 slop 后再精确拖 100px：时间轴走到约 0.26，
    // 最近阅读块（0ms）已滑走大半、标题块（100ms）刚起步、书架块（200ms）还没动。
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    final headerDelta = tester.getTopLeft(find.text('小说')).dx - headerBefore;
    final recentDelta = tester.getTopLeft(find.text('最近阅读')).dx - recentBefore;
    final shelfAfter = tester.getTopLeft(find.text('我的书架')).dx;
    expect(recentDelta, lessThan(-120), reason: '最近阅读块（0ms）应该先滑');
    expect(headerDelta, lessThan(0), reason: '标题块（100ms）随后开始');
    expect(
      headerDelta.abs(),
      lessThan(recentDelta.abs()),
      reason: '标题块应落后于最近阅读块',
    );
    expect(shelfAfter, closeTo(shelfBefore, 0.5), reason: '书架块（200ms）此时不应移动');

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(find.text('短剧'), findsWidgets);
  });

  /// 顶部固定页头的氛围渐变：小说/短剧各一套角度，切换面板时过渡到另一套。
  testWidgets('我的页-页头渐变随面板切换过渡', (tester) async {
    await pumpPreview(tester, const MinePage());
    TopGlow glow() => tester.widget<TopGlow>(find.byType(TopGlow));
    expect(glow().spec.begin, kNovelTopGlow.begin);

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(
      glow().spec.begin,
      kDramaTopGlow.begin,
      reason: '切到短剧后页头渐变应过渡成短剧那一套角度',
    );
  });

  /// 页头（图标 + 主标题 + 副标题）固定贴顶，和推荐页搜索框一样不跟着列表滚。
  testWidgets('我的页-页头固定贴顶不随列表滚动', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        for (var i = 1; i <= 12; i++)
          {'id': '$i', 'title': '书$i', 'cover': '', 'author': '作者$i'},
      ]),
    });
    await pumpPreview(tester, const MinePage());
    final header = find.text('小说');
    final headerBefore = tester.getTopLeft(header);
    final shelfBefore = tester.getTopLeft(find.text('我的书架'));

    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.text('小说'), findsOneWidget, reason: '页头必须始终可见');
    expect(tester.getTopLeft(header), headerBefore, reason: '页头固定贴顶，不随列表滚动');
    expect(
      tester.getTopLeft(find.text('我的书架')).dy,
      lessThan(shelfBefore.dy),
      reason: '页头下面的书架内容应该正常滚动',
    );
  });

  /// 短剧是镜像版式：标题/图标靠右；设置按钮只有一枚，随面板在屏幕内
  /// 从右侧滑到左侧，不再由两个面板各画一个。
  testWidgets('我的页-短剧标题与设置按钮左右镜像', (tester) async {
    await pumpPreview(tester, const MinePage());
    const pageWidth = 390.0;
    const gutter = 8.0;
    const iconBox = 34.0;
    const iconGap = 10.0;

    expect(
      tester.getTopLeft(find.text('小说')).dx,
      closeTo(gutter + iconBox + iconGap, 1),
    );
    final settingsIcon = find.byIcon(Icons.settings_outlined);
    expect(settingsIcon, findsOneWidget, reason: '小说/短剧共用同一个设置按钮');
    expect(
      tester.getTopLeft(settingsIcon).dx,
      greaterThan(pageWidth / 2),
      reason: '小说的设置按钮在右侧',
    );

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(
      tester.getTopRight(find.text('短剧')).dx,
      closeTo(pageWidth - (gutter + iconBox + iconGap), 1),
      reason: '短剧标题应与小说标题左右对称',
    );
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(
      tester.getTopLeft(settingsIcon).dx,
      lessThan(pageWidth / 2),
      reason: '同一个设置按钮应过渡到左侧',
    );
  });

  /// 缓存入口已挪到推荐页搜索框右侧的「已缓存」，这一页右下角只剩切换按钮。
  testWidgets('我的页-右下角只剩面板切换按钮', (tester) async {
    await pumpPreview(tester, const MinePage());
    expect(find.byKey(MinePage.switchButtonKey), findsOneWidget);
    expect(
      find.byIcon(Icons.download_outlined),
      findsNothing,
      reason: '悬浮缓存入口已删除',
    );
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });

  testWidgets('我的页（短剧）', (tester) async {
    await pumpPreview(tester, const MinePage());
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_drama_empty.png'),
    );
  });

  /// 过渡中：标题块已滑走大半、最近阅读块刚起步、书架块还没动（三块阶梯）。
  testWidgets('我的页-面板切换过程中', (tester) async {
    await pumpPreview(tester, const MinePage());
    final gesture = await tester.startGesture(const Offset(200, 500));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    final settings = tester.getRect(find.byIcon(Icons.settings_outlined));
    expect(settings.left, greaterThanOrEqualTo(0), reason: '设置按钮不能被滑出屏幕');
    expect(settings.right, lessThanOrEqualTo(390), reason: '设置按钮不能被滑出屏幕');
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('../goldens/mine_switch_mid.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
  });
}
