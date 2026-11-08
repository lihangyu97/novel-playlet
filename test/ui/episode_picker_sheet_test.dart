import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// 播放页「选集」弹层：78 集一个 tab、初始 tab 跟随当前集、点集回传绝对下标。
///
/// fake 模式照抄 test/ui/video_player_page_test.dart：用 FakeController 替换
/// 平台通道，不碰真实 AVPlayer。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('78 集一个 tab：初始 tab 跟随当前集，切 tab 点集后切到该集', (tester) async {
    await _pumpPlayer(tester);
    // 当前是第 81 集（固定下标 80），顶栏先确认初始状态。
    expect(find.text('第 81 集'), findsOneWidget);

    // 点底栏「选集」打开弹层。
    await tester.tap(find.byIcon(Icons.video_library_outlined));
    await tester.pumpAndSettle();
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('1-78'), findsOneWidget);
    expect(find.text('79-156'), findsOneWidget);
    expect(find.text('157-200'), findsOneWidget);

    // 当前集在 79-156 区间：默认选中第二个 tab，且该 tab 的首集 79 可见。
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 1, reason: '初始 tab 应包含当前集');
    expect(find.text('79'), findsOneWidget);

    // 切到最后一个 tab，点第 157 集。
    await tester.tap(find.text('157-200'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
      2,
      reason: '点 tab 标题应切到对应页',
    );
    expect(find.text('157'), findsOneWidget);
    await tester.tap(find.text('157'));
    await tester.pumpAndSettle();

    // 弹层关闭，播放页顶栏切到第 157 集。
    expect(find.text('157-200'), findsNothing);
    expect(find.text('第 157 集'), findsOneWidget);

    await _disposePlayer(tester);
  });
}

List<Chapter> _episodes(int count) => [
  for (var i = 0; i < count; i++) Chapter(id: 'e${i + 1}', title: ''),
];

Future<void> _pumpPlayer(WidgetTester tester) async {
  final store = _FakeSeriesStore(cachedFile: File('/tmp/episode.mp4'));
  final factory = _FakeFactory();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        offlineSeriesStoreProvider.overrideWithValue(store),
        playbackControllerFactoryProvider.overrideWithValue(factory.call),
      ],
      child: MaterialApp(
        home: VideoPlayerPage(
          args: VideoPlayArgs(
            seriesTitle: '测试短剧',
            episodes: _episodes(200),
            index: 80,
            seriesId: 's1',
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _disposePlayer(WidgetTester tester) async {
  // 主动卸载页面，取消 _hideTimer / _prefetchTimer / _spinnerTimer。
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 离线 store 的测试替身：固定返回一个存在的「离线文件」，跳过取流分支。
class _FakeSeriesStore extends OfflineSeriesStore {
  _FakeSeriesStore({this.cachedFile});

  final File? cachedFile;

  @override
  Future<File?> episodeFileIfCached(String seriesId, String episodeId) async =>
      cachedFile;
}

/// controller 工厂测试替身：只记录创建次数。
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
    await super.dispose();
  }
}
