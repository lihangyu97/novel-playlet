import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/detail/detail_common.dart';
import 'package:novel_playlet/app/widgets/detail_circle_button.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/detail/detail_action_bar.dart';
import 'package:novel_playlet/features/detail/detail_reviews_section.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/widgets/episode_picker.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 短剧详情页预览：Hero、收藏/播放栏、观看进度与选集分组。
///
/// 更新基线：`flutter test --update-goldens test/ui/video_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('封面 Hero 飞入', () {
    testWidgets('短剧列表点进详情：封面飞入并在返回时飞回', (tester) async {
      final fake = FakePreviewTransport()
        ..videoCoverUrl = 'https://example.com/drama-1.jpg';
      await pumpPreview(tester, const RecommendPage(), transport: fake);
      await tester.tap(find.text('短剧'));
      await tester.pumpAndSettle();
      final card = tester.widget<VideoCard>(find.byType(VideoCard).first);
      final tag = card.heroTag!;
      expect(tag, startsWith('cover-video-recommend-drama-'));

      await tester.tap(find.byType(VideoCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(VideoDetailPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '进详情时应在飞行',
      );
      final detailHero = tester.widget<Hero>(
        find
            .descendant(
              of: find.byType(VideoDetailPage),
              matching: find.byType(Hero),
            )
            .first,
      );
      expect(detailHero.tag, tag, reason: '短剧详情封面必须用同一个 tag 接住 Hero');

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(VideoDetailPage), findsOneWidget);

      Navigator.of(tester.element(find.byType(VideoDetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '从短剧详情返回时应执行反向封面飞行',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(VideoDetailPage), findsNothing);
    });

    testWidgets('短剧详情-加载中也先画封面（Hero 目标从第一帧就存在）', (tester) async {
      final fake = FakePreviewTransport()
        ..responseDelay = const Duration(milliseconds: 80);
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        cover: 'https://example.com/list-drama.jpg',
        episodeCount: 40,
      );
      await pumpPreview(
        tester,
        const VideoDetailPage(
          seriesId: 'v1',
          preview: preview,
          heroTag: 'cover-video-test-v1',
        ),
        transport: fake,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 30));
      // 背景/Hero 目标从第一帧就在；文字信息等接口回来再淡入，不再转圈。
      expect(find.byType(Hero), findsOneWidget);
      expect(find.text('测试短剧'), findsNothing, reason: '文字信息等数据回来再淡入');
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '详情加载不再显示转圈 loading',
      );
      final heightBefore = tester
          .getSize(find.byType(DetailCoverBackdrop))
          .height;

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('详情标题'), findsOneWidget);
      expect(find.text('8.2分'), findsOneWidget, reason: '短剧详情展示评分');
      expect(find.text('选集'), findsOneWidget);
      expect(
        tester.getSize(find.byType(DetailCoverBackdrop)).height,
        heightBefore,
        reason: '接口回来后背景高度不能变',
      );
    });

    testWidgets('短剧详情-接口回来后不替换列表封面（不闪）', (tester) async {
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        cover: 'https://example.com/list-drama.jpg',
        episodeCount: 40,
      );
      final fake = FakePreviewTransport()
        ..detailSeriesCoverUrl = 'https://example.com/detail-drama.jpg';
      await pumpPreview(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: fake,
      );
      final backdrop = tester.widget<DetailCoverBackdrop>(
        find.byType(DetailCoverBackdrop),
      );
      expect(backdrop.cover, preview.cover, reason: '短剧详情接口回来不应换图');
    });

    testWidgets('短剧详情-分类只在简介标签里出现一次', (tester) async {
      const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
      await pumpPreview(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: FakePreviewTransport(),
      );
      expect(find.text('全 40 集 · 1.2 万 次播放'), findsOneWidget);
      expect(find.text('全 40 集'), findsNothing, reason: '集数和播放量应在同一行');
      expect(find.text('都市'), findsOneWidget, reason: '分类只作为简介标签出现一次');
      expect(
        find.textContaining('都市 ·'),
        findsNothing,
        reason: '信息行不应再出现点拼接的分类',
      );
    });

    testWidgets('短剧详情-同一次进入内重建不重拉详情与选集', (tester) async {
      const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
      final fake = FakePreviewTransport();
      // 注入同一个 store 实例：saveVideoProgress 要 bump 页面监听的那个
      // videoRevision，进度 provider 才会刷新。
      final store = ReadingStore();
      await pumpPreview(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: fake,
        store: store,
      );
      int bundleCalls() => fake.calls
          .where(
            (call) =>
                // 剧评是独立请求，不参与「详情/选集」的计数。
                (call.startsWith('/api/v1/series/v1') &&
                    !call.startsWith('/api/v1/series/v1/comments')) ||
                call.startsWith('/api/v1/books/v1/directory'),
          )
          .length;
      expect(bundleCalls(), 2, reason: '进入详情时详情与选集各拉一次');

      // 收藏走 provider 乐观更新（按钮立即回显），页面因此重建一次。
      // 底栏按钮只有图标，收藏态用 书签空/书签实 区分。
      final actionBar = find.byType(DetailActionBar);
      await tester.tap(
        find.descendant(
          of: actionBar,
          matching: find.byIcon(Icons.bookmark_add_outlined),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(
        find.descendant(
          of: actionBar,
          matching: find.byIcon(Icons.bookmark_added_outlined),
        ),
        findsOneWidget,
        reason: '收藏应乐观回显，不等落盘',
      );

      // 播放页返回存进度会 bump videoRevision，进度 provider 刷新又让页面重建。
      await store.saveVideoProgress(
        seriesId: 'v1',
        title: '测试短剧',
        episodeIndex: 3,
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DetailCircleButton &&
              widget.semanticLabel == '继续观看 · 第 4 集',
        ),
        findsOneWidget,
        reason: '主按钮的读屏文案要跟上观看进度',
      );

      expect(bundleCalls(), 2, reason: '页面重建由 provider 驱动，不应重新请求上游');
    });
  });

  testWidgets('短剧详情-剧评卡片与「全部评论」弹层', (tester) async {
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    final fake = FakePreviewTransport()
      ..seriesCommentsPayload = <String, dynamic>{
        'code': 0,
        'data': <String, dynamic>{
          'data_list': <dynamic>[
            <String, dynamic>{
              'comment': <String, dynamic>{
                'comment_id': 'c1',
                'common': <String, dynamic>{
                  'content': <String, dynamic>{'text': '这部剧节奏很好'},
                  'user_info': <String, dynamic>{
                    'base_info': <String, dynamic>{'user_name': '小明'},
                  },
                  'create_timestamp': 1700000000,
                },
                'stat': <String, dynamic>{
                  'digg_count': '12',
                  'reply_count': '2',
                },
              },
            },
            <String, dynamic>{
              'comment': <String, dynamic>{
                'comment_id': 'c2',
                'common': <String, dynamic>{
                  'content': <String, dynamic>{'text': '第二集开始上头'},
                  'user_info': <String, dynamic>{
                    'base_info': <String, dynamic>{'user_name': '小红'},
                  },
                },
                'stat': <String, dynamic>{'digg_count': '3'},
              },
            },
          ],
          'common_list_info': <String, dynamic>{
            'total': '2',
            'cursor': '',
            'has_more': false,
          },
        },
      };
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: fake,
    );

    expect(find.text('剧评'), findsOneWidget, reason: '有剧评时应显示剧评区块');
    expect(find.text('这部剧节奏很好'), findsOneWidget, reason: '卡片只露第一条');
    expect(find.text('查看全部 2 条'), findsOneWidget);

    await tester.tap(find.text('查看全部 2 条'));
    await tester.pumpAndSettle();
    expect(find.text('共 2 条'), findsOneWidget);
    expect(find.text('第二集开始上头'), findsOneWidget, reason: '弹层里应能看到全部评论');
  });

  testWidgets('短剧详情-没有剧评：卡片保留并显示暂无评论', (tester) async {
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: FakePreviewTransport(),
    );

    expect(find.text('剧评'), findsOneWidget);
    expect(find.text('暂无评论'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailReviewsSection),
        matching: find.textContaining('查看全部'),
      ),
      findsNothing,
    );
  });

  testWidgets('短剧详情-底部收藏与播放栏', (tester) async {
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: FakePreviewTransport(),
    );
    final actionBar = find.byType(DetailActionBar);
    final favoriteButton = find.descendant(
      of: actionBar,
      matching: find.byIcon(Icons.bookmark_add_outlined),
    );
    expect(favoriteButton, findsOneWidget);
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(favoriteButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final favoriteActive = find.descendant(
      of: actionBar,
      matching: find.byIcon(Icons.bookmark_added_outlined),
    );
    expect(favoriteActive, findsOneWidget, reason: '底部收藏按钮应变成已收藏图标');
    final store = ReadingStore();
    expect(await store.isVideoOnShelf('v1'), isTrue);

    // 等「已收藏」snackbar 消失，避免它挡住底部按钮。
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(favoriteActive);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.bookmark_add_outlined),
      ),
      findsOneWidget,
    );
    expect(await store.isVideoOnShelf('v1'), isFalse);
  });

  testWidgets('短剧详情-有观看进度时显示继续观看', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '测试短剧',
      episodeIndex: 2,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: FakePreviewTransport(),
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DetailCircleButton &&
            widget.semanticLabel == '继续观看 · 第 3 集',
      ),
      findsOneWidget,
    );
  });

  group('短剧选集', () {
    testWidgets('默认展开，36 集一个 tab、每行 6 个、只显示集数', (tester) async {
      final fake = FakePreviewTransport()..directoryChapterCount = 80;
      const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 80);
      await pumpPreview(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: fake,
      );

      final episodeButtons = find.descendant(
        of: find.byType(EpisodePicker),
        matching: find.byType(OutlinedButton),
      );
      // 默认展开：直接看到选集和集数按钮。
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('共 80 集'), findsOneWidget);
      expect(episodeButtons, findsWidgets);

      // 36 集一个 tab，自动分组。
      expect(find.text('1-36'), findsOneWidget);
      expect(find.text('37-72'), findsOneWidget);
      expect(find.text('73-80'), findsOneWidget);
      // 只显示集数，没有「第 x 集」。
      expect(find.text('第 1 集'), findsNothing);
      expect(find.text('1'), findsOneWidget);

      // 一行 6 个：前 6 个的 y 相同，第 7 个换行。
      final firstRow = [
        for (var i = 1; i <= 6; i++) tester.getTopLeft(find.text('$i')),
      ];
      for (final position in firstRow) {
        expect(position.dy, closeTo(firstRow.first.dy, 0.5));
      }
      expect(
        tester.getTopLeft(find.text('7')).dy,
        greaterThan(firstRow.first.dy),
        reason: '一行应放 6 个，第 7 个换行',
      );

      // 切到第二个 tab，看到第 37 集。
      await tester.tap(find.text('37-72'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.text('37'), findsOneWidget);
      expect(find.text('36'), findsNothing);

      // 选集常驻展开，点标题不会收起。
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(episodeButtons, findsWidgets);
    });
  });

  testWidgets('短剧详情最下方展示短剧 ID，可一键复制', (tester) async {
    // 拦截系统通道，捕获 Clipboard.setData 写入的文本。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: FakePreviewTransport(),
    );
    // 滚到内容最下方：ID 卡片位于选集之后、底部操作栏之上。
    final footerText = find.descendant(
      of: find.byType(DetailIdFooter),
      matching: find.text('v1'),
    );
    await tester.scrollUntilVisible(
      footerText,
      240,
      scrollable: _verticalScrollable,
    );
    await tester.pumpAndSettle();
    expect(footerText, findsOneWidget);

    await tester.tap(find.byTooltip('复制短剧 ID'));
    await tester.pumpAndSettle();
    expect(copied, 'v1', reason: '复制的是完整 ID');
    expect(find.text('ID 已复制'), findsOneWidget, reason: '复制后弹浮动 SnackBar');
  });

  testWidgets('短剧详情加载中不先显示 ID 行，数据回来后才出现', (tester) async {
    // 回归：ID 行曾先于简介/选集出现，内容淡入后再被顶下去（视觉跳动）。
    final fake = FakePreviewTransport()
      ..responseDelay = const Duration(milliseconds: 120);
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 40);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: fake,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      find.byType(DetailIdFooter, skipOffstage: false),
      findsNothing,
      reason: '数据没回来前不应渲染 ID 行（否则会被简介/选集顶下去）',
    );

    // 数据回来 + 淡入完成。ID 行在内容最下方，可能在屏幕外，所以只断言
    // 它已进入部件树（skipOffstage: false）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(DetailIdFooter, skipOffstage: false),
      findsOneWidget,
      reason: '数据回来后 ID 行才出现',
    );
  });

  testWidgets('短剧详情-选集展开（36 集一个 tab、一行 6 个）', (tester) async {
    final fake = FakePreviewTransport()..directoryChapterCount = 80;
    const preview = VideoSeries(id: 'v1', title: '测试短剧', episodeCount: 80);
    await pumpPreview(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: fake,
    );
    await expectLater(
      find.byType(VideoDetailPage),
      matchesGoldenFile('../goldens/video_detail_episodes.png'),
    );
  });
}

/// 详情页外层 CustomScrollView 的纵向滚动；选集 tab 里还有横向 Scrollable。
final Finder _verticalScrollable = find
    .byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    )
    .first;
