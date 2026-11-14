import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/video_detail.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/detail/detail_action_bar.dart';
import 'package:novel_playlet/features/video/network_health.dart';
import 'package:novel_playlet/features/video/video_library_providers.dart';
import 'package:novel_playlet/features/video/playback_speed.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// 播放页行为回归：用 FakeController 替换平台通道，锁住「切集保留旧画面、
/// 倍速跨集继承、自动续播不弹控制条」这些纯 Dart 状态逻辑。
void main() {
  /// 记录页面下发的 SystemChrome 调用（全屏方向切换/状态栏显隐）。
  final systemCalls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    systemCalls.clear();
    // 全屏会调 SystemChrome.setPreferredOrientations / setEnabledSystemUIMode；
    // widget test 下没有平台实现，统一在这里吞掉并记录，避免抛 MissingPlugin。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          systemCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('进入播放页：控制条可见，倍速应用到 controller，改速实时下发', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    expect(factory.created, hasLength(1));
    final controller = factory.created.single;
    expect(controller.speeds, contains(1.0), reason: '初始化后要 apply 全局倍速');
    expect(find.text('测试短剧'), findsWidgets);
    expect(find.text('1.0x'), findsOneWidget);

    // 控制条默认可见（首次进入）。
    final opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .toList();
    expect(opacities, isNotEmpty);
    expect(opacities.every((widget) => widget.opacity == 1), isTrue);

    // 运行中改速：provider → 当前 controller 立即下发。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VideoPlayerPage)),
    );
    container.read(playbackSpeedProvider.notifier).setSpeed(2.0);
    await tester.pump();
    expect(controller.speeds.last, 2.0);
    expect(find.text('2.0x'), findsOneWidget);

    await _disposePlayer(tester);
  });

  testWidgets('底栏：选集 / 详情 / 本集评论，收藏缓存移进详情弹层', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    final api = _FakeApi();
    final container = await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: api,
    );

    // 底部入口：选集右边是详情，收藏/下载/顶部详情按钮都撤掉了。
    expect(find.byTooltip('选集'), findsOneWidget);
    expect(find.byTooltip('详情'), findsOneWidget);
    expect(find.byTooltip('本集评论'), findsOneWidget);
    expect(find.byTooltip('剧集详情'), findsNothing);
    expect(find.byTooltip('收藏'), findsNothing);
    expect(find.byTooltip('缓存'), findsNothing);

    await tester.tap(find.byTooltip('详情'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.byType(VideoDetailPage), findsOneWidget);
    expect(find.byTooltip('关闭详情'), findsOneWidget);
    // 弹层里只有收藏 + 缓存，没有播放/继续观看主按钮。
    final actionBar = find.byType(DetailActionBar);
    expect(actionBar, findsOneWidget);
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.bookmark_add_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.download_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsNothing,
    );

    // 收藏可以直接在弹层里完成，仍然只加不移。
    final shelfProvider = videoShelfStatusProvider('s1');
    for (var i = 0; i < 5 && container.read(shelfProvider).isLoading; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.bookmark_add_outlined),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(shelfProvider).value, isTrue);
    expect(
      find.descendant(
        of: actionBar,
        matching: find.byIcon(Icons.bookmark_added_outlined),
      ),
      findsOneWidget,
    );

    // 关掉弹层回到播放页。
    await tester.tap(find.byTooltip('关闭详情'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(VideoDetailPage), findsNothing);

    await _disposePlayer(tester);
  });

  testWidgets('进度条两侧显示时间；缓存档位清晰度只展示不可切换', (tester) async {
    final store = _FakeSeriesStore(
      cachedFile: File('/tmp/episode.mp4'),
      manifest: OfflineSeries(
        seriesId: 's1',
        title: '测试短剧',
        episodes: [
          OfflineEpisode(
            id: 'e1',
            title: '第 1 集',
            index: 0,
            variantName: '720P',
          ),
          OfflineEpisode(
            id: 'e2',
            title: '第 2 集',
            index: 1,
            variantName: '720P',
          ),
        ],
        qualityMaxHeight: 720,
      ),
    );
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory, api: _FakeApi());
    await tester.pump(const Duration(milliseconds: 100));

    // 当前时间在左、总时长在右（假 controller 固定 120s）。
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('02:00'), findsOneWidget);
    expect(
      tester.getCenter(find.text('00:00')).dx,
      lessThan(tester.getCenter(find.text('02:00')).dx),
    );

    // 缓存档位能拿到：展示 720P，且 chip 没有点击行为。
    expect(find.text('720P'), findsOneWidget);
    expect(find.byTooltip('当前清晰度（暂不支持切换）'), findsOneWidget);

    await _disposePlayer(tester);
  });

  testWidgets('内核缓存命中：直接播 mode=cached 的 /src，不再正常取流', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    final api = _FakeApi(cachedUrl: 'http://127.0.0.1:18931/src/e1.mp4');
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    expect(api.cachedCalls, 1, reason: '切集应先探本地缓存');
    expect(api.sourceCalls, 0, reason: '缓存命中不应再请求上游');
    expect(factory.created, hasLength(1));
    expect(factory.created.single.speeds, contains(1.0));

    await _disposePlayer(tester);
  });

  testWidgets('内核缓存未命中：stream 不可用时回退正常整集取流', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    // streamFails：模拟内核没有流式能力，验证整集下载兜底路径没被新优先级破坏。
    final api = _FakeApi(
      sourceUrl: 'http://127.0.0.1:18931/src/e1.mp4',
      streamFails: true,
    );
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    expect(api.cachedCalls, 1);
    expect(api.streamCalls, 1, reason: '在线取流先试 stream');
    expect(api.sourceCalls, 1, reason: 'stream 不可用时回退整集下载');
    expect(factory.created, hasLength(1));

    await _disposePlayer(tester);
  });

  testWidgets('在线优先 mode=stream：直接初始化 stream 地址，不等整集下载', (tester) async {
    const streamUrl = 'http://127.0.0.1:18931/src/e1-stream.mp4';
    const fallbackUrl = 'http://127.0.0.1:18931/src/e1-full.mp4';
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    final api = _FakeApi(streamUrl: streamUrl, sourceUrl: fallbackUrl);
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    expect(api.cachedCalls, 1, reason: '先探内核本地缓存');
    expect(api.streamCalls, 1, reason: '缓存未命中应优先请求 mode=stream');
    expect(api.sourceCalls, 0, reason: 'stream 成功就不该再走整集下载');
    expect(factory.created, hasLength(1));
    expect(
      factory.networkUrls.single,
      Uri.parse(streamUrl),
      reason: 'stream 拿到的回环地址直接进 controller.initialize',
    );
    expect(factory.created.single.value.isPlaying, isTrue);

    await _disposePlayer(tester);
  });

  testWidgets('stream 源初始化失败：回退一次默认整集取流并播放', (tester) async {
    const streamUrl = 'http://127.0.0.1:18931/src/e1-stream.mp4';
    const fallbackUrl = 'http://127.0.0.1:18931/src/e1-full.mp4';
    final store = _FakeSeriesStore();
    // 首个在线源 controller（stream 地址）initialize 抛错，模拟流式起播失败。
    final factory = _FakeFactory(failFirstNetworkInitialize: true);
    final api = _FakeApi(streamUrl: streamUrl, sourceUrl: fallbackUrl);
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    expect(api.streamCalls, 1);
    expect(api.sourceCalls, 1, reason: 'stream 起播失败要回退一次默认取流');
    expect(factory.created, hasLength(2));
    expect(
      factory.networkUrls[0],
      Uri.parse(streamUrl),
      reason: '第一次先尝试 stream 地址',
    );
    expect(
      factory.networkUrls[1],
      Uri.parse(fallbackUrl),
      reason: '回退到默认整集下载地址',
    );
    expect(
      factory.created.first.disposeCount,
      1,
      reason: '失败的 controller 必须释放',
    );
    expect(factory.created.last.value.isPlaying, isTrue, reason: '回退后仍要正常播放');
    expect(find.text('视频播放失败'), findsNothing, reason: '不允许把原本能播的集变成错误页');
    expect(find.byType(VideoPlayer), findsOneWidget);

    await _disposePlayer(tester);
  });

  testWidgets('预取下一集使用 mode=stream：立即拿回 /src 地址并触发后台下载', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    final api = _FakeApi();
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    // 当前集起播 5s 后预取下一集（_schedulePrefetch）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(api.cachedCalls, greaterThanOrEqualTo(2), reason: '当前集与预取各探一次本地缓存');
    expect(api.sourceCalls, 0, reason: '预取应优先 stream，而不是等整集下载');
    expect(
      api.streamEpisodeIds,
      contains('e2'),
      reason: '预取下一集应请求 mode=stream',
    );
    expect(
      api.streamEpisodeIds.where((id) => id == 'e2'),
      hasLength(1),
      reason: '同一集只预取一次',
    );

    await _disposePlayer(tester);
  });

  testWidgets('疑似离线（近期网络失败）：未缓存集跳过取流，手动重试强制联网', (tester) async {
    final health = NetworkHealth()..recordFailure();
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    // streamFails：重试后先试 stream 失败、再回退整集取流，两条都算联网。
    final api = _FakeApi(
      sourceUrl: 'http://127.0.0.1:18931/src/e1.mp4',
      streamFails: true,
    );
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: api,
      overrides: [networkHealthProvider.overrideWithValue(health)],
    );

    expect(api.cachedCalls, 1, reason: '本地缓存探测照旧');
    expect(api.streamCalls, 0, reason: '疑似离线时连 stream 也不再请求');
    expect(api.sourceCalls, 0, reason: '疑似离线时不应再付一次完整取流等待');
    expect(find.text('该集未离线缓存'), findsOneWidget);

    // 用户点重试：清掉疑似离线，强制走一次完整网络请求。
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(api.streamCalls, 1, reason: '手动重试先试 stream，必须真的联网');
    expect(api.sourceCalls, 1, reason: 'stream 不可用时回退整集取流');
    expect(health.isSuspectedOffline, isFalse, reason: '取流成功清除疑似离线');

    await _disposePlayer(tester);
  });

  testWidgets('新集真正出画面后会再补一次倍速（iOS 起播会重置 rate）', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    final container = await _pumpPlayer(tester, store: store, factory: factory);
    container.read(playbackSpeedProvider.notifier).setSpeed(2.0);
    await tester.pump();

    final controller = factory.created.single;
    final callsBeforeFrame = controller.speeds.length;
    expect(controller.speeds.last, 2.0);

    // 模拟起播后首帧 position 前进：页面必须补设一次倍速，防止 iOS 16+
    // 把 rate 复位成 1.0（UI 2x、实际 1x 的根因）。
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 1),
      isPlaying: true,
    );
    await tester.pump();
    expect(controller.speeds.length, greaterThan(callsBeforeFrame));
    expect(controller.speeds.last, 2.0);

    await _disposePlayer(tester);
  });

  testWidgets('上滑切下一集、下滑回上一集；不再有上下集按钮', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    // 底部控制条不再提供上一集/下一集按钮：切集只靠上下滑与选集弹层。
    expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    expect(factory.created, hasLength(1));

    // 第 1 集继续下滑：没有上一集，回弹，不创建新 controller。
    await tester.drag(find.byType(PageView), const Offset(0, 600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(factory.created, hasLength(1), reason: '第 1 集下滑不应切集');
    expect(find.text('第 1 集'), findsWidgets);

    // 上滑：滑过半预热第 2 集，落定后提交；旧 controller 落定即释放。
    await tester.drag(find.byType(PageView), const Offset(0, -600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(factory.created, hasLength(2), reason: '上滑应切到下一集');
    expect(find.text('第 2 集'), findsWidgets);
    expect(tester.widget<PageView>(find.byType(PageView)).controller?.page, 1);
    expect(
      factory.created.first.disposeCount,
      1,
      reason: '落定提交时旧 controller 立即释放',
    );
    expect(factory.created[1].value.isPlaying, isTrue, reason: '提交后新集开始播放');

    // 下滑回第 1 集：预热上一集并提交。
    await tester.drag(find.byType(PageView), const Offset(0, 600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(factory.created, hasLength(3), reason: '下滑应回到上一集并重建 controller');
    expect(find.text('第 1 集'), findsWidgets);
    expect(factory.created[1].disposeCount, 1);

    await _disposePlayer(tester);
  });

  testWidgets('滑过半又滑回原页：不换集、不重播，预热 controller 被丢弃', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);
    final first = factory.created.single;
    expect(first.value.isPlaying, isTrue);

    // 600 高视口：拖过 300 会让 PageView 判定翻到下一页；不松手再拖回来。
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -420));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 420));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // 预热可能已完成（多一个 controller，被丢弃）或还在飞（token 失效后
    // 自行 dispose），两种都不算错；关键是原集 controller 不能被重建/释放。
    expect(
      factory.created.length,
      lessThanOrEqualTo(2),
      reason: '回弹不应触发 _open 重建原集',
    );
    if (factory.created.length == 2) {
      expect(
        factory.created[1].disposeCount,
        1,
        reason: '滑回原页应丢弃预热 controller，不能留着占内存',
      );
    }
    expect(
      factory.created.first.disposeCount,
      0,
      reason: '原集 controller 不能被释放/重建（否则会从头重播）',
    );
    expect(tester.widget<PageView>(find.byType(PageView)).controller?.page, 0);
    expect(find.text('第 1 集'), findsWidgets);
    expect(first.value.isPlaying, isTrue, reason: '取消滑动后继续播放');

    await _disposePlayer(tester);
  });

  testWidgets('选集弹层跳集：翻到目标页并加载', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    await tester.tap(find.byTooltip('选集'));
    await tester.pumpAndSettle();
    // 弹层里集数只显示数字，点「2」回到播放页选中第 2 集。
    await tester.tap(find.text('2'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(factory.created, hasLength(2), reason: '选集跳集应加载目标集');
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller?.page,
      1,
      reason: '选集跳集后 PageView 应停在目标页',
    );
    expect(find.text('第 2 集'), findsWidgets);

    await _disposePlayer(tester);
  });

  testWidgets('播完自动续播：整页滑到下一集、倍速继承、控制条不弹出', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    final container = await _pumpPlayer(tester, store: store, factory: factory);
    container.read(playbackSpeedProvider.notifier).setSpeed(2.0);
    await tester.pump();

    final first = factory.created.single;
    // 模拟播完：position 到尾部且不再播放 → 页面触发自动翻页续播。
    first.value = first.value.copyWith(
      position: first.value.duration,
      isPlaying: false,
    );
    await tester.pump();
    // 翻页动画 280ms + 新集初始化。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    await tester.pump();

    expect(factory.created, hasLength(2), reason: '自动续播应创建下一集 controller');
    final second = factory.created[1];
    expect(second.speeds, contains(2.0), reason: '新 controller 必须继承倍速');
    // 保留帧在新集出画面后才释放（翻页动画期间旧画面不会提前变黑）。
    second.value = second.value.copyWith(
      position: const Duration(seconds: 1),
      isPlaying: true,
    );
    await tester.pump();
    expect(first.disposeCount, 1, reason: '新集出画面后释放旧 controller');

    // 自动续播不弹控制条：两处 chrome 都是隐藏态。
    final opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .toList();
    expect(opacities, isNotEmpty);
    expect(
      opacities.every((widget) => widget.opacity == 0),
      isTrue,
      reason: '自动切集不应该把控制条弹出来',
    );

    await _disposePlayer(tester);
  });

  testWidgets('播放中 3.5s 后控制条自动隐藏，点屏幕重新唤出', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);
    final controller = factory.created.single;
    controller.value = controller.value.copyWith(isPlaying: true);

    // 自动隐藏计时到期。
    await tester.pump(const Duration(milliseconds: 3700));
    await tester.pump();
    var opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .toList();
    expect(opacities.every((widget) => widget.opacity == 0), isTrue);

    // 点画面重新唤出控制条。
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .toList();
    expect(opacities.every((widget) => widget.opacity == 1), isTrue);

    await _disposePlayer(tester);
  });

  testWidgets('横屏视频：视频下方显示「全屏观看」，控制条不再有全屏按钮', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    // 16:9 视频在 800x600 测试窗口里画面高 450、居中（顶部 75），提示贴画面
    // 下边缘 8px，所以文字应在画面底边（525）之下、屏幕底边之上。
    const videoHeight = 800 / (1280 / 720);
    const videoTop = (600 - videoHeight) / 2;
    final hintRect = tester.getRect(find.text('全屏观看'));
    expect(
      hintRect.top,
      greaterThan(videoTop + videoHeight),
      reason: '提示应贴在真实视频画面下方',
    );
    expect(hintRect.top, lessThan(600));

    // 底部控制条里不再有全屏图标：旧入口的 tooltip 与图标都不应存在。
    expect(find.byTooltip('全屏'), findsNothing);
    expect(find.byTooltip('退出全屏'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);
    // 唯一保留的全屏图标是视频下方的提示本身。
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    // 倍速 chip 移到操作行最右。
    expect(find.byTooltip('播放速度'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('播放速度')).dx,
      greaterThan(400),
      reason: '倍速入口应在控制区右下角',
    );

    await _disposePlayer(tester);
  });

  testWidgets('横屏视频：点「全屏观看」进全屏并隐藏提示，返回键退全屏不离开页面', (tester) async {
    // 用真机竖屏尺寸：默认 800x600 测试窗口下底部控制条会压到画面下缘。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPushedPlayer(tester, store: store, factory: factory);

    expect(find.text('全屏观看'), findsOneWidget);
    await tester.tap(find.text('全屏观看'));
    await tester.pumpAndSettle();

    // 进全屏：提示隐藏，同时请求横屏。
    expect(find.text('全屏观看'), findsNothing);
    expect(
      systemCalls.any(
        (call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List<Object?>).contains(
              'DeviceOrientation.landscapeLeft',
            ),
      ),
      isTrue,
      reason: '点全屏提示应请求横屏方向',
    );

    // 顶栏返回键：全屏时只退全屏，不能把播放页 pop 掉（否则会露出宿主页）。
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerPage), findsOneWidget, reason: '全屏返回只退全屏');
    expect(find.text('全屏观看'), findsOneWidget, reason: '退出全屏后提示重新出现');
    expect(find.text('打开播放页'), findsNothing, reason: '播放页不能被 pop 掉');
    expect(
      systemCalls.any(
        (call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List<Object?>).contains(
              'DeviceOrientation.portraitUp',
            ),
      ),
      isTrue,
      reason: '退出全屏应恢复竖屏',
    );

    await _disposePlayer(tester);
  });

  testWidgets('竖屏视频：不显示「全屏观看」提示', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory(size: const Size(720, 1280));
    await _pumpPlayer(tester, store: store, factory: factory);

    expect(find.text('全屏观看'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_rounded), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsNothing);

    await _disposePlayer(tester);
  });

  testWidgets('回环 -1004：一次性恢复成功后自动重开这一集，不显示错误页', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _LoopbackFailingFactory(failures: 1);
    var ensureCalls = 0;
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: _FakeApi(cachedUrl: 'http://127.0.0.1:18931/src/e1.mp4'),
      ensureLoopback: () async {
        ensureCalls += 1;
        return true;
      },
    );
    await tester.pump();
    await tester.pump();
    expect(ensureCalls, 1, reason: '回环 connect refused 只做一次探活恢复');
    expect(factory.created, 2, reason: '恢复后必须重建 controller 重开这一集');
    expect(factory.healthy, hasLength(1));
    expect(factory.healthy.single.value.isPlaying, isTrue);
    expect(factory.healthy.single.speeds, contains(1.0));
    expect(find.text('本地视频服务未响应'), findsNothing);
    expect(find.text('AVPlayer 播放失败'), findsNothing);
    expect(find.byType(VideoPlayer), findsOneWidget);

    await _disposePlayer(tester);
  });

  testWidgets('回环 -1004：恢复失败时显示专用文案', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _LoopbackFailingFactory(failures: 1);
    var ensureCalls = 0;
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: _FakeApi(cachedUrl: 'http://127.0.0.1:18931/src/e1.mp4'),
      ensureLoopback: () async {
        ensureCalls += 1;
        return false;
      },
    );
    await tester.pump();
    await tester.pump();

    expect(ensureCalls, 1);
    expect(factory.created, 1, reason: '恢复失败不重建 controller');
    expect(find.text('本地视频服务未响应'), findsOneWidget);
    expect(find.textContaining('TN2277'), findsOneWidget);
    expect(find.text('AVPlayer 播放失败'), findsNothing);

    await _disposePlayer(tester);
  });

  testWidgets('回环 -1004：恢复后仍失败时不再继续恢复（有界）', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _LoopbackFailingFactory(failures: 2);
    var ensureCalls = 0;
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: _FakeApi(cachedUrl: 'http://127.0.0.1:18931/src/e1.mp4'),
      ensureLoopback: () async {
        ensureCalls += 1;
        return true;
      },
    );
    await tester.pump();
    await tester.pump();

    expect(ensureCalls, 1, reason: '只允许一次自愈重试，不能循环');
    expect(factory.created, 2);
    expect(find.text('本地视频服务未响应'), findsOneWidget);

    await _disposePlayer(tester);
  });

  testWidgets('相邻集占位：目录标题本身是「第 N 集」时不重复渲染集数', (tester) async {
    // 预热 initialize 先挂起，让相邻页停在「预热中」占位，能稳定看到文案。
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _GatedFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    await tester.pump();

    expect(factory.gated, hasLength(1));
    expect(
      find.text('第 2 集'),
      findsOneWidget,
      reason: '标题已经是「第 2 集」，占位不要再把集数显示一遍',
    );
    expect(find.textContaining('第 2 集 · 第 2 集'), findsNothing);

    factory.gated.single.gate.complete();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await _disposePlayer(tester);
  });

  testWidgets('相邻集封面走统一封面组件 NovelCover，不直接用 Image.network', (tester) async {
    // 预热 initialize 先挂起：相邻页稳定停在占位（封面暗化底）上。
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _GatedFactory();
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      cover: 'https://example.com/drama-cover.jpg',
    );

    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();

    expect(
      find.byType(NovelCover),
      findsWidgets,
      reason: '相邻页封面要走 AppImageCache，滑动/离线时能复用列表页已缓存的图',
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is NetworkImage,
      ),
      findsNothing,
      reason: '不允许再用 Image.network：它各建 provider、无磁盘缓存',
    );

    factory.gated.single.gate.complete();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await _disposePlayer(tester);
  });

  testWidgets('拖动过半、预热完成后，下一集首帧不等落定就上屏', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _GatedFactory();
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: _FakeApi(sourceUrl: 'http://127.0.0.1:18931/src/e2.mp4'),
    );

    // 视口 600：往上分多步拖动，越过一半（onPageChanged 触发预热）但不松手。
    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 3; i += 1) {
      await gesture.moveBy(const Offset(0, -180));
      await tester.pump();
    }

    expect(factory.gated, hasLength(1), reason: '滑过半应开始预热下一集');
    expect(
      find.byType(VideoPlayer),
      findsOneWidget,
      reason: '预热未完成时只有当前集挂了播放器',
    );

    // 预热完成：还没松手、没落定，相邻页就该切到真实的（暂停）首帧。
    factory.gated.single.gate.complete();
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(VideoPlayer),
      findsNWidgets(2),
      reason: '预热完成后拖动中就要渲染下一集首帧，不能等落定',
    );

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await _disposePlayer(tester);
  });
  testWidgets('拖动刚开始（未过半）就按方向预热目标集', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);
    expect(factory.created, hasLength(1));

    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 2; i += 1) {
      await gesture.moveBy(const Offset(0, -180));
      await tester.pump();
    }
    await tester.pump();

    final page = tester
        .widget<PageView>(find.byType(PageView))
        .controller
        ?.page;
    expect(page, isNotNull);
    expect(page!, lessThan(0.5), reason: '此时还没滑过半');
    expect(factory.created, hasLength(2), reason: '方向一确定（上滑下一集）就应开始预热，不等滑过半');

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await _disposePlayer(tester);
  });

  testWidgets('落定提交不重建相邻页的 VideoPlayer（避免 iOS 闪黑）', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    final gesture = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 3; i += 1) {
      await gesture.moveBy(const Offset(0, -180));
      await tester.pump();
    }
    await tester.pump();
    expect(find.byType(VideoPlayer), findsNWidgets(2));

    // 预热页（第 2 集）的 VideoPlayer element：提交后应原地保留。
    final pendingElement = find
        .byType(VideoPlayer)
        .evaluate()
        .firstWhere(
          (element) =>
              (element.widget as VideoPlayer).controller == factory.created[1],
        );

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(
      identical(tester.element(find.byType(VideoPlayer)), pendingElement),
      isTrue,
      reason: '提交只应换 controller/onTap，不能重建 platform view',
    );

    await _disposePlayer(tester);
  });
  testWidgets('横屏全屏下也能上下滑切集，并保持全屏', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    await tester.tap(find.text('全屏观看'));
    await tester.pumpAndSettle();
    expect(find.text('全屏观看'), findsNothing);

    // 全屏横屏里上滑：应切到第 2 集，并留在全屏。
    await tester.drag(find.byType(PageView), const Offset(0, -700));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(factory.created, hasLength(2));
    expect(tester.widget<PageView>(find.byType(PageView)).controller?.page, 1);
    expect(factory.created[1].value.isPlaying, isTrue);
    expect(find.text('第 2 集'), findsWidgets);
    expect(find.text('全屏观看'), findsNothing, reason: '横屏视频切集后仍应留在全屏，不弹回竖屏');

    await _disposePlayer(tester);
  });

  testWidgets('全屏横屏切到竖屏视频会自动退回竖屏', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory(
      sizes: const [Size(1280, 720), Size(720, 1280)],
    );
    await _pumpPlayer(tester, store: store, factory: factory);

    await tester.tap(find.text('全屏观看'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(0, -700));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(factory.created, hasLength(2));
    expect(
      systemCalls.any(
        (call) =>
            call.method == 'SystemChrome.setPreferredOrientations' &&
            (call.arguments as List<Object?>).contains(
              'DeviceOrientation.portraitUp',
            ),
      ),
      isTrue,
      reason: '切到竖屏视频应恢复竖屏',
    );
    expect(find.text('全屏观看'), findsNothing, reason: '竖屏视频没有全屏入口');

    await _disposePlayer(tester);
  });

  testWidgets('旋转（进出全屏）后 PageView 仍停在当前集', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    await _pumpPlayer(tester, store: store, factory: factory);

    await tester.tap(find.text('全屏观看'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(0, -700));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.widget<PageView>(find.byType(PageView)).controller?.page, 1);

    // 模拟横屏后的 viewport（高度变矮）：pixel offset 不换算的话 page 会
    // 变成 844/390 ≈ 2.16，停在两页之间。
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();

    expect(
      tester.widget<PageView>(find.byType(PageView)).controller?.page,
      1,
      reason: '旋转后应拉回当前集，不能停在两页之间',
    );
    await _disposePlayer(tester);
  });
}

const _episodes = <Chapter>[
  Chapter(id: 'e1', title: '第 1 集'),
  Chapter(id: 'e2', title: '第 2 集'),
];

/// controller 工厂替身共用的调用形状（与 `PlaybackControllerFactory` 一致）。
abstract interface class _ControllerFactory {
  VideoPlayerController call({File? file, Uri? networkUrl});
}

Future<ProviderContainer> _pumpPlayer(
  WidgetTester tester, {
  required _FakeSeriesStore store,
  required _ControllerFactory factory,
  ApiClient? api,
  Future<bool> Function()? ensureLoopback,
  List<Override> overrides = const [],
  String cover = '',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        offlineSeriesStoreProvider.overrideWithValue(store),
        playbackControllerFactoryProvider.overrideWithValue(factory.call),
        if (api != null) apiClientProvider.overrideWithValue(api),
        if (ensureLoopback != null)
          backendEnsureLoopbackProvider.overrideWithValue(ensureLoopback),
      ],
      child: MaterialApp(
        home: VideoPlayerPage(
          args: VideoPlayArgs(
            seriesTitle: '测试短剧',
            episodes: _episodes,
            index: 0,
            seriesId: 's1',
            cover: cover,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(VideoPlayerPage)),
  );
}

/// 把播放页 push 到宿主页之上：验证「全屏时返回只退全屏」——如果返回键真的
/// pop 了页面，播放页会消失、露出宿主页的「打开播放页」按钮。
Future<ProviderContainer> _pumpPushedPlayer(
  WidgetTester tester, {
  required _FakeSeriesStore store,
  required _ControllerFactory factory,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        offlineSeriesStoreProvider.overrideWithValue(store),
        playbackControllerFactoryProvider.overrideWithValue(factory.call),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VideoPlayerPage(
                      args: VideoPlayArgs(
                        seriesTitle: '测试短剧',
                        episodes: _episodes,
                        index: 0,
                        seriesId: 's1',
                      ),
                    ),
                  ),
                ),
                child: const Text('打开播放页'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开播放页'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(VideoPlayerPage)),
  );
}

Future<void> _disposePlayer(WidgetTester tester) async {
  // 主动卸载页面，取消 _hideTimer / _prefetchTimer / _spinnerTimer。
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 离线 store 的测试替身：固定返回一个存在的「离线文件」。
class _FakeSeriesStore extends OfflineSeriesStore {
  _FakeSeriesStore({this.cachedFile, this.manifest});

  final File? cachedFile;
  final OfflineSeries? manifest;

  @override
  Future<File?> episodeFileIfCached(String seriesId, String episodeId) async =>
      cachedFile;

  @override
  Future<OfflineSeries?> read(String seriesId) async => manifest;
}

/// ApiClient 测试替身：只关心缓存探测、`mode=stream` 优先与整集下载兜底的分流。
class _FakeApi extends ApiClient {
  _FakeApi({
    this.cachedUrl,
    this.sourceUrl,
    this.streamUrl,
    this.streamFails = false,
  }) : super(BackendTransport(port: 18931));

  final String? cachedUrl;
  final String? sourceUrl;

  /// `mode=stream` 返回的地址；默认按集 id 拼 `/src/<id>.mp4`。
  final String? streamUrl;

  /// 模拟内核不支持/取不到 stream 源：让 stream 请求抛错，验证整集下载兜底。
  final bool streamFails;

  int cachedCalls = 0;
  int sourceCalls = 0;
  int streamCalls = 0;

  /// 记录每次 stream 取流的集，断言「在线优先 stream」「预取也用 stream」。
  final List<String> streamEpisodeIds = <String>[];

  @override
  Future<String?> cachedVideoUrl(String episodeId) async {
    cachedCalls += 1;
    return cachedUrl;
  }

  @override
  Future<VideoDetail> videoDetail(String seriesId) async =>
      VideoDetail(id: seriesId, title: '测试短剧', episodeCount: _episodes.length);

  @override
  Future<List<Chapter>> videoEpisodes(String seriesId) async => _episodes;

  @override
  Future<BookCommentPage> seriesComments(
    String seriesId, {
    int count = 10,
    String cursor = '',
    int sort = 1,
  }) async => BookCommentPage.empty;

  @override
  Future<VideoSource> videoSource(
    String episodeId, {
    bool refresh = false,
    int? maxHeight,
    bool stream = false,
  }) async {
    if (stream) {
      streamCalls += 1;
      streamEpisodeIds.add(episodeId);
      if (streamFails) throw Exception('stream 取流失败');
      return VideoSource(
        url: streamUrl ?? 'http://127.0.0.1:18931/src/$episodeId.mp4',
        streaming: true,
      );
    }
    sourceCalls += 1;
    return VideoSource(
      url: sourceUrl ?? 'http://127.0.0.1:18931/src/$episodeId.mp4',
    );
  }
}

/// controller 工厂测试替身：记录创建次数、倍速下发与在线地址。
class _FakeFactory implements _ControllerFactory {
  _FakeFactory({
    this.size = const Size(1280, 720),
    this.failFirstNetworkInitialize = false,
    this.sizes,
  });

  /// 假视频的画面尺寸（决定横/竖屏与全屏入口是否出现）。
  final Size size;

  /// 按创建顺序给每个 controller 指定尺寸（切换横/竖屏视频的用例）。
  final List<Size>? sizes;

  /// 首个在线源 controller 的 initialize 抛错（模拟 stream 起播失败）。
  final bool failFirstNetworkInitialize;

  final List<_FakeController> created = <_FakeController>[];

  /// 每次创建 controller 时传入的在线地址（file 源为 null）。
  final List<Uri?> networkUrls = <Uri?>[];

  bool _failedOnce = false;

  @override
  VideoPlayerController call({File? file, Uri? networkUrl}) {
    networkUrls.add(networkUrl);
    final fail =
        failFirstNetworkInitialize && !_failedOnce && networkUrl != null;
    if (fail) _failedOnce = true;
    final index = created.length;
    final controller = _FakeController(
      size: sizes != null && index < sizes!.length ? sizes![index] : size,
      failInitialize: fail,
    );
    created.add(controller);
    return controller;
  }
}

/// 不碰平台通道的 VideoPlayerController：只维护 VideoPlayerValue。
class _FakeController extends VideoPlayerController {
  _FakeController({
    this.size = const Size(1280, 720),
    this.failInitialize = false,
  }) : super.file(File('/tmp/fake.mp4'));

  /// 默认 16:9 横屏（全屏入口可见）；竖屏场景传 720x1280。
  final Size size;

  /// initialize 是否抛错（模拟流式源起播失败，验证回退整集下载）。
  final bool failInitialize;

  final List<double> speeds = <double>[];

  @override
  Future<void> initialize() async {
    if (failInitialize) {
      throw PlatformException(
        code: 'VideoError',
        message: 'Failed to load video: The operation could not be completed.',
        details: null,
      );
    }
    value = VideoPlayerValue(
      duration: const Duration(seconds: 120),
      size: size,
      isInitialized: true,
    );
  }

  @override
  Future<void> setLooping(bool looping) async {
    value = value.copyWith(isLooping: looping);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    speeds.add(speed);
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    // 基类的 dispose 只清理 ValueNotifier/_creatingCompleter；fake 没走
    // platform create，_creatingCompleter 为 null，不会碰平台通道。
    await super.dispose();
  }

  int disposeCount = 0;
}

/// 预热 controller 的 initialize 由测试放行：用来验证「预热完成时，
/// 拖动中的相邻页要立即重建出首帧，而不是等到落定」。
class _GatedController extends _FakeController {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> initialize() async {
    await gate.future;
    await super.initialize();
  }
}

/// 首个 controller（当前集）立即可用；后续 controller（预热）走 [_GatedController]。
class _GatedFactory implements _ControllerFactory {
  final List<_GatedController> gated = <_GatedController>[];
  bool _first = true;

  @override
  VideoPlayerController call({File? file, Uri? networkUrl}) {
    if (_first) {
      _first = false;
      return _FakeController();
    }
    final controller = _GatedController();
    gated.add(controller);
    return controller;
  }
}

/// 前 [failures] 个 controller 在 initialize() 抛 -1004（iOS 长时间后台回来
/// 的真机形态），之后返回正常 fake：锁「播放页对 -1004 只做一次有界恢复」。
class _LoopbackFailingFactory implements _ControllerFactory {
  _LoopbackFailingFactory({this.failures = 1});

  final int failures;
  final List<_FakeController> healthy = <_FakeController>[];
  int created = 0;
  int failed = 0;

  @override
  VideoPlayerController call({File? file, Uri? networkUrl}) {
    created += 1;
    if (failed < failures) {
      failed += 1;
      return _ConnectRefusedController();
    }
    final controller = _FakeController();
    healthy.add(controller);
    return controller;
  }
}

/// 模拟 vendored video_player_avfoundation 的真实错误形态：只有
/// localizedDescription，没有数字 code。
class _ConnectRefusedController extends _FakeController {
  @override
  Future<void> initialize() async {
    throw PlatformException(
      code: 'VideoError',
      message: 'Failed to load video: Could not connect to the server.',
      details: null,
    );
  }
}
