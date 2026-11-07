import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/widgets/states.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/widgets/offline_download_button.dart';
import 'package:novel_playlet/features/video/offline_playback.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/video_detail_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 离线播放取源决策 + 短剧详情离线兜底。
///
/// 播放器本身依赖 AVPlayer（真机/插件），这里只测不碰平台通道的部分：
/// 1) `resolveOfflineEpisode` 的纯逻辑（有文件→本地；无文件→网络；离线→明确错误）；
/// 2) `isOfflineNetworkFailure` 的失败分类；
/// 3) 详情接口失败时用 `series.json` manifest 兜底。
void main() {
  group('resolveOfflineEpisode', () {
    test('有离线文件 → 本地文件（离线与否都优先本地）', () {
      final file = File('/tmp/offline-episode.mp4');
      for (final offline in [false, true]) {
        final plan = resolveOfflineEpisode(cachedFile: file, offline: offline);
        expect(plan.source, EpisodePlaybackSource.localFile);
        expect(plan.isLocal, isTrue);
        expect(plan.file, same(file));
      }
    });

    test('没有离线文件、网络在线 → 走网络', () {
      final plan = resolveOfflineEpisode(cachedFile: null, offline: false);
      expect(plan.source, EpisodePlaybackSource.network);
      expect(plan.isLocal, isFalse);
      expect(plan.file, isNull);
    });

    test('没有离线文件、确认离线 → 明确错误（不发起网络请求）', () {
      final plan = resolveOfflineEpisode(cachedFile: null, offline: true);
      expect(plan.source, EpisodePlaybackSource.offlineMiss);
      expect(EpisodePlaybackPlan.offlineMissReason, contains('该集未离线缓存，请联网后观看'));
    });
  });

  group('isOfflineNetworkFailure', () {
    test('内核超时算离线', () {
      expect(
        isOfflineNetworkFailure(
          ApiException('HTTP 504', kind: ApiErrorKind.timeout),
        ),
        isTrue,
      );
    });

    test('unknown + 连接类消息算离线（内核把 reqwest 网络错误映射成 unknown）', () {
      expect(
        isOfflineNetworkFailure(
          ApiException(
            'error sending request for url: dns error: failed to lookup address',
          ),
        ),
        isTrue,
      );
      expect(
        isOfflineNetworkFailure(ApiException('Network is unreachable')),
        isTrue,
      );
    });

    test('业务类错误不算离线，保留原来的错误页', () {
      expect(
        isOfflineNetworkFailure(
          ApiException('HTTP 500', kind: ApiErrorKind.upstream5xx),
        ),
        isFalse,
      );
      expect(
        isOfflineNetworkFailure(
          ApiException('HTTP 403', kind: ApiErrorKind.deviceFailed),
        ),
        isFalse,
      );
      expect(
        isOfflineNetworkFailure(ApiException('上游没有返回可播放地址（video_url 为空）')),
        isFalse,
      );
    });

    test('SocketException 算离线；499 取消不算', () {
      expect(
        isOfflineNetworkFailure(const SocketException('no route to host')),
        isTrue,
      );
      expect(
        isOfflineNetworkFailure(TimeoutException('backend cancelled')),
        isFalse,
      );
      expect(
        isOfflineNetworkFailure(TimeoutException('took too long')),
        isTrue,
      );
    });
  });

  group('短剧详情离线兜底', () {
    late Directory tempDir;
    late OfflinePaths paths;
    late OfflineSeriesStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('offline_playback_test_');
      paths = OfflinePaths(rootDirectory: () async => tempDir);
      store = OfflineSeriesStore(paths: paths);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> seedManifest() => store.begin(
      OfflineSeries(
        seriesId: 'v1',
        title: '离线剧名',
        episodes: const [
          OfflineEpisode(id: 'e1', title: '第 1 集', index: 0),
          OfflineEpisode(id: 'e2', title: '第 2 集', index: 1),
        ],
      ),
    );

    test('详情/选集接口失败时用 manifest 兜底', () async {
      await seedManifest();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(_FailingTransport())),
          offlinePathsProvider.overrideWithValue(paths),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(videoDetailBundleProvider('v1'), (_, _) {});
      addTearDown(sub.close);

      final bundle = await container.read(
        videoDetailBundleProvider('v1').future,
      );
      expect(bundle.detail.title, '离线剧名');
      expect(bundle.detail.episodeCount, 2);
      expect(bundle.episodes.map((episode) => episode.id), ['e1', 'e2']);
      expect(bundle.episodes.first.title, '第 1 集');
    });

    test('没有离线 manifest 时仍然抛错（页面走错误页 + 重试）', () async {
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(_FailingTransport())),
          offlinePathsProvider.overrideWithValue(paths),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(videoDetailBundleProvider('v1'), (_, _) {});
      addTearDown(sub.close);

      await expectLater(
        container.read(videoDetailBundleProvider('v1').future),
        throwsA(isA<ApiException>()),
      );
    });

    testWidgets('断网 + 有离线 manifest：详情页正常展示（不是错误页）', (tester) async {
      // widget 测试的 fake async 下真实磁盘 IO 不会完成（见 test/ui/preview_harness
      // 的说明），所以注入内存版离线 store；播放器 `file://` 秒开路径不在这里
      // 覆盖（需要 AVPlayer），由 offline_playback 的纯逻辑单测锁行为。
      final fakeStore = _FakeSeriesStore(
        OfflineSeries(
          seriesId: 'v1',
          title: '离线剧名',
          episodes: const [
            OfflineEpisode(id: 'e1', title: '第 1 集', index: 0),
            OfflineEpisode(id: 'e2', title: '第 2 集', index: 1),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(_FailingTransport())),
            offlineSeriesStoreProvider.overrideWithValue(fakeStore),
          ],
          child: const MaterialApp(home: VideoDetailPage(seriesId: 'v1')),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      // 用离线 manifest 的剧名/选集渲染，而不是「剧集加载失败」。
      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('离线剧名'), findsOneWidget);
      expect(find.text('全 2 集'), findsOneWidget);
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('第 1 集'), findsNothing, reason: '选集只显示集数，不显示「第 x 集」');
      // 底栏：缓存整剧入口（未缓存态，文字在按钮里）+ 主按钮（可播）。
      expect(find.byType(OfflineDownloadButton), findsOneWidget);
      expect(find.text('缓存'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('播放'), findsOneWidget);
    });
  });
}

/// 内存版离线 store：widget 测试不做真实磁盘 IO（fake async 下不会完成）。
class _FakeSeriesStore extends OfflineSeriesStore {
  _FakeSeriesStore(this._series) : super(paths: _unusedPaths);

  final OfflineSeries _series;

  @override
  Future<OfflineSeries?> read(String seriesId) async =>
      seriesId == _series.seriesId ? _series : null;

  @override
  Future<File?> episodeFileIfCached(String seriesId, String episodeId) async =>
      null;
}

final OfflinePaths _unusedPaths = OfflinePaths(
  rootDirectory: () async => Directory('${Directory.systemTemp.path}/unused'),
);

/// 所有请求都 500：模拟断网/上游不可用。
class _FailingTransport extends BackendTransport {
  _FailingTransport() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async => BackendResponse(
    500,
    Uint8List.fromList(utf8.encode(jsonEncode({'message': 'boom'}))),
    'application/json',
  );
}
