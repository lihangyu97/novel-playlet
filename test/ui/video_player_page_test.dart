import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/video/network_health.dart';
import 'package:novel_playlet/features/video/playback_speed.dart';
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

  testWidgets('内核缓存未命中：回退正常取流', (tester) async {
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    final api = _FakeApi(sourceUrl: 'http://127.0.0.1:18931/src/e1.mp4');
    await _pumpPlayer(tester, store: store, factory: factory, api: api);

    expect(api.cachedCalls, 1);
    expect(api.sourceCalls, 1);
    expect(factory.created, hasLength(1));

    await _disposePlayer(tester);
  });

  testWidgets('疑似离线（近期网络失败）：未缓存集跳过取流，手动重试强制联网', (tester) async {
    final health = NetworkHealth()..recordFailure();
    final store = _FakeSeriesStore();
    final factory = _FakeFactory();
    final api = _FakeApi(sourceUrl: 'http://127.0.0.1:18931/src/e1.mp4');
    await _pumpPlayer(
      tester,
      store: store,
      factory: factory,
      api: api,
      overrides: [networkHealthProvider.overrideWithValue(health)],
    );

    expect(api.cachedCalls, 1, reason: '本地缓存探测照旧');
    expect(api.sourceCalls, 0, reason: '疑似离线时不应再付一次完整取流等待');
    expect(find.text('该集未离线缓存'), findsOneWidget);

    // 用户点重试：清掉疑似离线，强制走一次完整网络请求。
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(api.sourceCalls, 1, reason: '手动重试必须真的联网');
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

    // 上滑：翻到第 2 集；旧画面在旧页上留到新集真正出画面（同旧行为）。
    await tester.drag(find.byType(PageView), const Offset(0, -600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(factory.created, hasLength(2), reason: '上滑应切到下一集');
    expect(find.text('第 2 集'), findsWidgets);
    expect(tester.widget<PageView>(find.byType(PageView)).controller?.page, 1);
    final second = factory.created[1];
    expect(factory.created.first.disposeCount, 0, reason: '新集出画面前旧帧还在');
    second.value = second.value.copyWith(
      position: const Duration(seconds: 1),
      isPlaying: true,
    );
    await tester.pump();
    expect(
      factory.created.first.disposeCount,
      1,
      reason: '新集出画面后释放旧 controller',
    );

    // 下滑回第 1 集。
    await tester.drag(find.byType(PageView), const Offset(0, 600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(factory.created, hasLength(3), reason: '下滑应回到上一集并重建 controller');
    expect(find.text('第 1 集'), findsWidgets);
    final third = factory.created[2];
    third.value = third.value.copyWith(
      position: const Duration(seconds: 1),
      isPlaying: true,
    );
    await tester.pump();
    expect(factory.created[1].disposeCount, 1);

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
          args: const VideoPlayArgs(
            seriesTitle: '测试短剧',
            episodes: _episodes,
            index: 0,
            seriesId: 's1',
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
  _FakeSeriesStore({this.cachedFile});

  final File? cachedFile;

  @override
  Future<File?> episodeFileIfCached(String seriesId, String episodeId) async =>
      cachedFile;
}

/// ApiClient 测试替身：只关心缓存探测与正常取流的分流。
class _FakeApi extends ApiClient {
  _FakeApi({this.cachedUrl, this.sourceUrl})
    : super(BackendTransport(port: 18931));

  final String? cachedUrl;
  final String? sourceUrl;
  int cachedCalls = 0;
  int sourceCalls = 0;

  @override
  Future<String?> cachedVideoUrl(String episodeId) async {
    cachedCalls += 1;
    return cachedUrl;
  }

  @override
  Future<VideoSource> videoSource(
    String episodeId, {
    bool refresh = false,
    int? maxHeight,
  }) async {
    sourceCalls += 1;
    return VideoSource(url: sourceUrl ?? 'http://127.0.0.1:18931/src/e1.mp4');
  }
}

/// controller 工厂测试替身：记录创建次数与倍速下发记录。
class _FakeFactory implements _ControllerFactory {
  _FakeFactory({this.size = const Size(1280, 720)});

  /// 假视频的画面尺寸（决定横/竖屏与全屏入口是否出现）。
  final Size size;

  final List<_FakeController> created = <_FakeController>[];

  @override
  VideoPlayerController call({File? file, Uri? networkUrl}) {
    final controller = _FakeController(size: size);
    created.add(controller);
    return controller;
  }
}

/// 不碰平台通道的 VideoPlayerController：只维护 VideoPlayerValue。
class _FakeController extends VideoPlayerController {
  _FakeController({this.size = const Size(1280, 720)})
    : super.file(File('/tmp/fake.mp4'));

  /// 默认 16:9 横屏（全屏入口可见）；竖屏场景传 720x1280。
  final Size size;

  final List<double> speeds = <double>[];

  @override
  Future<void> initialize() async {
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
