import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/video/playback_speed.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// 播放页行为回归：用 FakeController 替换平台通道，锁住「切集保留旧画面、
/// 倍速跨集继承、自动续播不弹控制条」这些纯 Dart 状态逻辑。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  testWidgets('播完自动续播：保留上一帧、倍速继承、控制条不弹出', (tester) async {
    final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
    final factory = _FakeFactory();
    final container = await _pumpPlayer(tester, store: store, factory: factory);
    container.read(playbackSpeedProvider.notifier).setSpeed(2.0);
    await tester.pump();

    final first = factory.created.single;
    // 模拟播完：position 到尾部且不再播放 → 页面触发自动下一集。
    first.value = first.value.copyWith(
      position: first.value.duration,
      isPlaying: false,
    );
    await tester.pump();
    await tester.pump();

    expect(factory.created, hasLength(2), reason: '自动续播应创建下一集 controller');
    final second = factory.created[1];
    expect(second.speeds, contains(2.0), reason: '新 controller 必须继承倍速');

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

    // 新集还没出画面时，旧集最后一帧继续垫在下面。
    expect(find.byType(VideoPlayer), findsNWidgets(2));

    // 新集 position 前进后释放旧帧。
    second.value = second.value.copyWith(
      position: const Duration(seconds: 1),
      isPlaying: true,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(VideoPlayer), findsOneWidget);

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
}

const _episodes = <Chapter>[
  Chapter(id: 'e1', title: '第 1 集'),
  Chapter(id: 'e2', title: '第 2 集'),
];

Future<ProviderContainer> _pumpPlayer(
  WidgetTester tester, {
  required _FakeSeriesStore store,
  required _FakeFactory factory,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        offlineSeriesStoreProvider.overrideWithValue(store),
        playbackControllerFactoryProvider.overrideWithValue(factory.call),
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

/// controller 工厂测试替身：记录创建次数与倍速下发记录。
class _FakeFactory {
  final List<_FakeController> created = <_FakeController>[];

  VideoPlayerController call({File? file, Uri? networkUrl}) {
    final controller = _FakeController();
    created.add(controller);
    return controller;
  }
}

/// 不碰平台通道的 VideoPlayerController：只维护 VideoPlayerValue。
class _FakeController extends VideoPlayerController {
  _FakeController() : super.file(File('/tmp/fake.mp4'));

  final List<double> speeds = <double>[];

  @override
  Future<void> initialize() async {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 120),
      size: Size(1280, 720),
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
