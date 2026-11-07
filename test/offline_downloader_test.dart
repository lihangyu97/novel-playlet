import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_downloader.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载器状态机：缺口跳过 / 批失败回退单章 / 失败不中断 / 连续失败暂停 /
/// 取消清理 / 容量上限 / 短剧流式落盘（全部用临时目录 + 内存 fake 网络）。
///
/// 下载节奏参数在测试里覆写成 0 时长，用例不需要真等 200ms/500ms。
void main() {
  // Notifier.build 会挂 WidgetsBindingObserver（前台限制），测试里先初始化
  // 绑定；真实 App 里由 main() 的 runApp 完成。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late OfflinePaths paths;
  late OfflineBookStore bookStore;
  late OfflineSeriesStore seriesStore;
  late _FakeNetwork network;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('offline_dl_test_');
    paths = OfflinePaths(rootDirectory: () async => tempRoot);
    bookStore = OfflineBookStore(paths: paths);
    seriesStore = OfflineSeriesStore(paths: paths);
    network = _FakeNetwork();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
  });

  List<Chapter> chapters(int count) => [
    for (var i = 0; i < count; i++)
      Chapter(id: 'c$i', title: '第${i + 1}章', index: i),
  ];

  List<Chapter> episodes(int count) => [
    for (var i = 0; i < count; i++)
      Chapter(id: 'e$i', title: '第${i + 1}集', index: i),
  ];

  /// 建容器并等启动恢复跑完，避免恢复态覆盖新任务。
  Future<ProviderContainer> makeContainer({
    OfflineSeriesStore? seriesStoreOverride,
  }) async {
    final container = ProviderContainer(
      overrides: [
        offlinePathsProvider.overrideWithValue(paths),
        offlineNetworkProvider.overrideWithValue(network),
        offlineDownloadSettingsProvider.overrideWithValue(
          const OfflineDownloadSettings(
            batchGap: Duration.zero,
            retryDelay: Duration.zero,
            progressInterval: Duration.zero,
            manifestInterval: Duration.zero,
          ),
        ),
        if (seriesStoreOverride != null)
          offlineSeriesStoreProvider.overrideWithValue(seriesStoreOverride),
      ],
    );
    addTearDown(container.dispose);
    container.read(offlineDownloaderProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return container;
  }

  Future<void> startNovel(
    ProviderContainer container, {
    String bookId = 'b1',
    List<Chapter>? items,
  }) => container
      .read(offlineDownloaderProvider.notifier)
      .startNovelBook(
        bookId: bookId,
        title: '测试书',
        cover: '',
        chapters: items ?? chapters(3),
      );

  group('小说整本', () {
    test('跳过已缓存章，只把缺口交给网络', () async {
      await bookStore.writeChapter(
        'b1',
        const ChapterContent(id: 'c0', title: '旧', paragraphs: ['旧正文']),
      );
      final container = await makeContainer();
      await startNovel(container, items: chapters(3));

      expect(network.batchCalls, hasLength(1));
      expect(network.batchCalls.single, ['c1', 'c2']);
      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.done);
      expect(state.completed, 3);
      expect(state.total, 3);
      expect(await bookStore.readChapter('b1', 'c1'), isNotNull);
      // 已缓存章的正文不能被覆盖。
      expect((await bookStore.readChapter('b1', 'c0'))!.paragraphs, ['旧正文']);
    });

    test('整批失败回退单章接口', () async {
      network.batchThrows = true;
      final container = await makeContainer();
      await startNovel(container, items: chapters(2));

      expect(network.batchCalls, hasLength(1));
      expect(network.singleCalls, ['c0', 'c1']);
      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.done);
      expect(state.completed, 2);
    });

    test('单章失败记失败但不中断整本', () async {
      network.emptyInBatch.add('c2');
      network.failSingles.add('c2');
      final container = await makeContainer();
      await startNovel(container, items: chapters(5));

      final state = container.read(offlineDownloaderProvider)!;
      expect(state.completed, 4);
      expect(state.status, OfflineTaskStatus.paused);
      expect(state.error, contains('1 章'));
      expect(network.singleCalls, ['c2'], reason: '只有批里缺失的那章走单章回退');
    });

    test('连续 3 章失败暂停，不再继续请求', () async {
      network.batchThrows = true;
      network.failSingles.addAll({'c0', 'c1', 'c2', 'c3', 'c4'});
      final container = await makeContainer();
      await startNovel(container, items: chapters(5));

      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.paused);
      expect(state.error, contains('网络异常，任务已暂停'));
      expect(state.completed, 0);
      expect(network.singleCalls, [
        'c0',
        'c1',
        'c2',
      ], reason: '第 3 次失败后应停在批次边界');
    });

    test('容量超限抛 OfflineQuotaExceeded（带 used/cap）', () async {
      await bookStore.begin(
        OfflineBook(
          bookId: 'big',
          title: '大文件',
          chapters: const [],
          bytes: OfflineBookStore.novelCapBytes,
        ),
      );
      final container = await makeContainer();
      await expectLater(
        startNovel(container, items: chapters(1)),
        throwsA(
          isA<OfflineQuotaExceeded>()
              .having(
                (error) => error.usedBytes,
                'usedBytes',
                OfflineBookStore.novelCapBytes,
              )
              .having(
                (error) => error.capBytes,
                'capBytes',
                OfflineBookStore.novelCapBytes,
              ),
        ),
      );
      expect(container.read(offlineDownloaderProvider), isNull);
    });

    test('取消：不再落新章、清掉任务记录、保留 manifest', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      network.batchEntered = entered;
      network.batchGate = gate;
      final container = await makeContainer();
      final downloader = container.read(offlineDownloaderProvider.notifier);
      final run = startNovel(container, items: chapters(40));

      await entered.future;
      // 有任务在跑时，再启动第二个要被挡下。
      await expectLater(
        startNovel(container, bookId: 'b2', items: chapters(1)),
        throwsA(isA<OfflineTaskBusyException>()),
      );
      final cancelRun = downloader.cancel();
      gate.complete();
      await Future.wait([run, cancelRun]);

      expect(container.read(offlineDownloaderProvider), isNull);
      expect(await OfflineTaskStore().read(), isNull);
      expect(
        await bookStore.missingChapterIds('b1', chapters(40)),
        hasLength(40),
        reason: '取消后已完成内容保留，但本次已取消章节不得落盘',
      );
    });

    test('启动恢复：running 降级成 paused（避免一启动就偷偷下载）', () async {
      await OfflineTaskStore().write(
        OfflineTask(
          kind: OfflineTaskKind.novel,
          id: 'b1',
          title: '书',
          completed: 1,
          total: 2,
          status: OfflineTaskStatus.running,
        ),
      );
      final container = await makeContainer();
      final restored = container.read(offlineDownloaderProvider);
      expect(restored?.status, OfflineTaskStatus.paused);
      expect(restored?.error, contains('重启'));
      expect(
        (await OfflineTaskStore().read())?.status,
        OfflineTaskStatus.paused,
        reason: '恢复后的状态要写回持久化',
      );
    });
  });

  group('短剧整剧', () {
    Future<void> startVideo(
      ProviderContainer container, {
      String seriesId = 's1',
      List<Chapter>? items,
    }) => container
        .read(offlineDownloaderProvider.notifier)
        .startVideoSeries(
          seriesId: seriesId,
          title: '测试短剧',
          cover: '',
          episodes: items ?? episodes(2),
        );

    test('跳过已缓存集，其余集流式落盘并 commit', () async {
      // 预缓存 e0（模拟上次已下载完：manifest + 文件都在）。
      await seriesStore.begin(
        OfflineSeries(
          seriesId: 's1',
          title: '测试短剧',
          episodes: const [
            OfflineEpisode(
              id: 'e0',
              title: '第1集',
              index: 0,
              bytes: 2,
              cached: true,
            ),
            OfflineEpisode(id: 'e1', title: '第2集', index: 1),
          ],
          completed: 1,
          bytes: 2,
        ),
      );
      final part = await seriesStore.partFile('s1', 'e0');
      await part.writeAsBytes([9, 9]);
      await seriesStore.commitEpisode('s1', 'e0', bytes: 2);
      network.videoBytes['e1'] = [1, 2, 3, 4];

      final container = await makeContainer();
      await startVideo(container, items: episodes(2));

      expect(network.videoSourceCalls, ['e1']);
      expect(await seriesStore.hasEpisode('s1', 'e1'), isTrue);
      final file = await seriesStore.episodeFile('s1', 'e1');
      expect(await file!.length(), 4);
      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.done);
      expect(state.completed, 2);
      expect(state.bytes, 6);
    });

    test('单集失败重试 1 次后暂停，且不留下 .part', () async {
      network.failStreams.add('e0');
      final container = await makeContainer();
      await startVideo(container, items: episodes(1));

      expect(network.streamCalls, hasLength(2), reason: '失败应重试 1 次');
      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.paused);
      expect(state.error, contains('1 集'));
      expect(await seriesStore.hasEpisode('s1', 'e0'), isFalse);

      final dir = await paths.seriesDir('s1');
      final leftovers = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.part')) {
          leftovers.add(entity);
        }
      }
      expect(leftovers, isEmpty, reason: '半截文件必须清掉');
    });

    test('集内取消：删 .part、不 commit、已完成集保留', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      network.streamEntered = entered;
      network.streamGate = gate;
      final container = await makeContainer();
      final downloader = container.read(offlineDownloaderProvider.notifier);
      // 不 await：任务会卡在集内流上，等测试触发取消。
      final run = startVideo(container, items: episodes(1));
      await entered.future;

      final cancelRun = downloader.cancel();
      gate.complete();
      await Future.wait([run, cancelRun]);

      expect(await seriesStore.hasEpisode('s1', 'e0'), isFalse);
      expect(container.read(offlineDownloaderProvider), isNull);
      final dir = await paths.seriesDir('s1');
      final leftovers = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.part')) {
          leftovers.add(entity);
        }
      }
      expect(leftovers, isEmpty);
    });

    test('40 集整剧不会在开始时被额度估算误挡（线上真实 case）', () async {
      // 曾经的 bug：按「缺失集数 × 150MB」预估算，40 集 ≈ 6GiB 直接超过 3GiB
      // 上限，表现为刚点下载就报「空间不足」。现在只在区已满时才拒绝。
      for (var i = 0; i < 40; i++) {
        network.videoBytes['e$i'] = [1, 2];
      }
      final container = await makeContainer();
      await startVideo(container, items: episodes(40));

      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.done);
      expect(state.completed, 40);
    });

    test('下到一半触及本区上限：暂停并提示，不再继续下载', () async {
      final smallCapStore = OfflineSeriesStore(paths: paths, capBytes: 8);
      for (var i = 0; i < 3; i++) {
        network.videoBytes['e$i'] = List.filled(4, 1);
      }
      final container = await makeContainer(seriesStoreOverride: smallCapStore);
      await startVideo(container, items: episodes(3));

      final state = container.read(offlineDownloaderProvider)!;
      expect(state.status, OfflineTaskStatus.paused);
      expect(state.completed, 2);
      expect(state.error, contains('空间不足'));
      expect(await smallCapStore.hasEpisode('s1', 'e2'), isFalse);
    });

    test('视频容量超限同样抛 OfflineQuotaExceeded', () async {
      await seriesStore.begin(
        OfflineSeries(
          seriesId: 'big',
          title: '大剧',
          episodes: const [],
          bytes: OfflineSeriesStore.videoCapBytes,
        ),
      );
      final container = await makeContainer();
      await expectLater(
        startVideo(container, items: episodes(1)),
        throwsA(isA<OfflineQuotaExceeded>()),
      );
    });
  });

  group('测速', () {
    test('短剧下载中采样到网速，完成后速度归 0', () async {
      network.chunkedBytes = [
        List<int>.filled(8192, 1),
        List<int>.filled(8192, 1),
        List<int>.filled(8192, 1),
        List<int>.filled(8192, 1),
      ];
      network.chunkDelay = const Duration(milliseconds: 25);
      final container = await makeContainer();

      final speedSeen = Completer<int>();
      final subscription = container.listen(offlineDownloaderProvider, (
        previous,
        next,
      ) {
        final speed = next?.speedBytesPerSecond ?? 0;
        if (speed > 0 && !speedSeen.isCompleted) speedSeen.complete(speed);
      });
      addTearDown(subscription.close);

      final run = container
          .read(offlineDownloaderProvider.notifier)
          .startVideoSeries(
            seriesId: 's1',
            title: '测试短剧',
            cover: '',
            episodes: episodes(1),
          );
      final speed = await speedSeen.future.timeout(const Duration(seconds: 2));
      expect(speed, greaterThan(0), reason: '下载中必须能采样到正网速');

      await run;
      final done = container.read(offlineDownloaderProvider)!;
      expect(done.status, OfflineTaskStatus.done);
      expect(done.speedBytesPerSecond, 0, reason: '完成后不能残留运行中网速');
    });

    test('暂停 / 恢复后的任务速度归 0', () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      network.streamEntered = entered;
      network.streamGate = gate;
      final container = await makeContainer();
      final downloader = container.read(offlineDownloaderProvider.notifier);
      final run = downloader.startVideoSeries(
        seriesId: 's1',
        title: '测试短剧',
        cover: '',
        episodes: episodes(1),
      );

      await entered.future;
      await downloader.pause();
      gate.complete();
      await run;

      final paused = container.read(offlineDownloaderProvider)!;
      expect(paused.status, OfflineTaskStatus.paused);
      expect(paused.speedBytesPerSecond, 0, reason: '暂停态不保留网速');

      expect(await downloader.resume(), isTrue);
      final done = container.read(offlineDownloaderProvider)!;
      expect(done.status, OfflineTaskStatus.done);
      expect(done.speedBytesPerSecond, 0, reason: '恢复并完成后同样归 0');
    });

    test('speedBytesPerSecond 是瞬态字段：不进 JSON、回读为 0', () {
      final task = OfflineTask(
        kind: OfflineTaskKind.video,
        id: 's1',
        title: '剧',
        speedBytesPerSecond: 123456,
        status: OfflineTaskStatus.running,
      );
      expect(task.toJson().containsKey('speedBytesPerSecond'), isFalse);
      final decoded = OfflineTask.tryFromJson(
        Map<String, dynamic>.from(task.toJson()),
      );
      expect(decoded, isNotNull);
      expect(decoded!.speedBytesPerSecond, 0);
    });
  });

  group('任务模型', () {
    test('done 的状态文案是「已完成」，不能显示成「已暂停」', () {
      expect(offlineTaskStatusLabel(OfflineTaskStatus.done), '已完成');
      expect(offlineTaskStatusLabel(OfflineTaskStatus.paused), '已暂停');
      expect(offlineTaskStatusLabel(OfflineTaskStatus.failed), '下载失败');
      expect(offlineTaskStatusLabel(OfflineTaskStatus.running), '下载中…');
    });

    test('OfflineTask JSON 往返保留状态与进度', () {
      final task = OfflineTask(
        kind: OfflineTaskKind.video,
        id: 's1',
        title: '剧',
        cover: 'c',
        completed: 3,
        total: 5,
        bytes: 1024,
        status: OfflineTaskStatus.paused,
        error: '网络异常',
      );
      final decoded = OfflineTask.tryFromJson(
        Map<String, dynamic>.from(task.toJson()),
      );
      expect(decoded, isNotNull);
      expect(decoded!.kind, OfflineTaskKind.video);
      expect(decoded.status, OfflineTaskStatus.paused);
      expect(decoded.completed, 3);
      expect(decoded.bytes, 1024);
      expect(decoded.error, '网络异常');
      expect(decoded.progress, 0.6);
    });
  });
}

/// 内存 fake：只实现下载器用到的 4 个动作，可按用例注入失败/门闩。
class _FakeNetwork implements OfflineNetwork {
  final batchCalls = <List<String>>[];
  final singleCalls = <String>[];
  final videoSourceCalls = <String>[];
  final streamCalls = <String>[];

  /// 批响应里"缺失"的章（触发单章回退）。
  final emptyInBatch = <String>{};
  final failSingles = <String>{};
  final failStreams = <String>{};
  final videoBytes = <String, List<int>>{};
  bool batchThrows = false;

  /// 取消/并发用例：卡住第一批请求，等到用例放行。
  Completer<void>? batchGate;
  Completer<void>? batchEntered;

  /// 视频集内取消用例：卡住一集的流，等到用例放行。
  Completer<void>? streamGate;
  Completer<void>? streamEntered;

  /// 测速用例：把流拆成多块、块间加延迟，模拟真实下载节奏。
  List<List<int>>? chunkedBytes;
  Duration chunkDelay = Duration.zero;

  ChapterContent _content(Chapter chapter) => ChapterContent(
    id: chapter.id,
    title: '标题${chapter.id}',
    paragraphs: ['正文${chapter.id}'],
  );

  @override
  Future<Map<String, ChapterContent>> chaptersBatch(
    List<Chapter> chapters, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    batchCalls.add([for (final chapter in chapters) chapter.id]);
    final entered = batchEntered;
    if (entered != null && !entered.isCompleted) {
      batchEntered = null;
      entered.complete();
    }
    final gate = batchGate;
    if (gate != null) {
      batchGate = null;
      await gate.future;
    }
    if (batchThrows) throw StateError('batch down');
    return {
      for (final chapter in chapters)
        if (!emptyInBatch.contains(chapter.id)) chapter.id: _content(chapter),
    };
  }

  @override
  Future<ChapterContent> chapter(String chapterId, {String title = ''}) async {
    singleCalls.add(chapterId);
    if (failSingles.contains(chapterId)) {
      throw ApiException('单章失败：$chapterId');
    }
    return ChapterContent(
      id: chapterId,
      title: title.isEmpty ? '标题$chapterId' : title,
      paragraphs: ['正文$chapterId'],
    );
  }

  @override
  Future<VideoSource> videoSource(String episodeId) async {
    videoSourceCalls.add(episodeId);
    return VideoSource(url: 'http://127.0.0.1:9/$episodeId.mp4');
  }

  @override
  Future<OfflineVideoStream> openVideoStream(String url) async {
    streamCalls.add(url);
    final id = url.split('/').last.replaceAll('.mp4', '');
    if (failStreams.contains(id)) {
      // 模拟流读到一半失败：下载器应删掉已创建的 .part。
      return OfflineVideoStream(
        bytes: Stream<List<int>>.error(ApiException('stream down：$id')),
      );
    }
    final gate = streamGate;
    if (gate != null) {
      streamGate = null;
      return OfflineVideoStream(bytes: _gatedBytes(gate), contentLength: 3);
    }
    final chunks = chunkedBytes;
    if (chunks != null) {
      return OfflineVideoStream(
        bytes: _delayedChunks(chunks),
        contentLength: chunks.fold<int>(0, (sum, chunk) => sum + chunk.length),
      );
    }
    final bytes = videoBytes[id] ?? const [1, 2, 3];
    return OfflineVideoStream(
      bytes: Stream<List<int>>.fromIterable([bytes]),
      contentLength: bytes.length,
    );
  }

  /// 分块 + 块间延迟，用于验证下载中的网速采样。
  Stream<List<int>> _delayedChunks(List<List<int>> chunks) async* {
    for (final chunk in chunks) {
      await Future<void>.delayed(chunkDelay);
      yield chunk;
    }
  }

  /// 第一块后卡住，用于验证"集内取消：删 part、不 commit"。
  Stream<List<int>> _gatedBytes(Completer<void> gate) async* {
    final entered = streamEntered;
    if (entered != null && !entered.isCompleted) {
      streamEntered = null;
      entered.complete();
    }
    yield const [1, 2];
    await gate.future;
    yield const [3];
  }
}
