import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_book_store.dart';
import '../../core/storage/offline/offline_series.dart';
import '../../core/storage/offline/offline_series_store.dart';
import '../../data/api/api_client.dart';
import '../../data/models/chapter.dart';
import '../../data/models/chapter_content.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/video_source.dart';
import 'cache_providers.dart';
import 'download_quality.dart';
import 'offline_diag.dart';
import 'offline_queue.dart';
import 'offline_task.dart';

/// 离线区剩余空间不足（软上限），由 UI 弹「已用 / 上限」并引导去管理页清理。
class OfflineQuotaExceeded implements Exception {
  const OfflineQuotaExceeded({
    required this.kind,
    required this.usedBytes,
    required this.capBytes,
  });

  final OfflineTaskKind kind;

  /// 本区已经占用的字节数（manifest 统计值）。
  final int usedBytes;

  /// 本区软上限（[OfflineBookStore.novelCapBytes] / [OfflineSeriesStore.videoCapBytes]）。
  final int capBytes;

  @override
  String toString() =>
      'OfflineQuotaExceeded(kind=${kind.name}, used=$usedBytes, cap=$capBytes)';
}

/// 一次 `start*` 的结果。
///
/// `started`：没有别的任务，立刻开始下载；`queued`：已有任务在跑，本次已排进
/// 等待队列（当前任务收尾后自动开始）。UI 用这个结果给「已加入队列」提示。
enum OfflineStartDisposition { started, queued }

/// 下载器需要的网络动作。
///
/// 单独抽成接口是为了让下载器的状态机/重试/断点逻辑可以在纯内存 fake 上
/// 单测（ApiClient 是具体类，不方便 mock）。生产实现是 [ApiOfflineNetwork]。
abstract interface class OfflineNetwork {
  /// 批量取正文（内核 `/api/v1/chapters/batch`，约 20 章/批）。
  Future<Map<String, ChapterContent>> chaptersBatch(
    List<Chapter> chapters, {
    Duration timeout = const Duration(seconds: 40),
  });

  /// 单章回退。
  Future<ChapterContent> chapter(String chapterId, {String title = ''});

  /// 取一集的明文流地址（内核下载整集密文到临时缓存后返回 `/src/...`）。
  /// [maxHeight] 为下载清晰度上限（短边 ≤ N 的最高档）。
  Future<VideoSource> videoSource(String episodeId, {int? maxHeight});

  /// 拉取明文流（不整集读进内存）。
  Future<OfflineVideoStream> openVideoStream(String url);
}

/// 一段内容流 + 可选的 content-length（用于集内字节进度展示）。
class OfflineVideoStream {
  const OfflineVideoStream({
    required this.bytes,
    this.contentLength,
    this.close,
  });

  final Stream<List<int>> bytes;
  final int? contentLength;

  /// 释放底层连接（HttpClient 等）；下载器在 finally 里调用。
  final Future<void> Function()? close;
}

/// 生产实现：ApiClient + `dart:io HttpClient`。
///
/// 用 HttpClient 而不是引 http 包：离线落盘是明文 mp4 流，`HttpClient` 的
/// `Stream<List<int>>` 正好边收边写，不新增依赖。
class ApiOfflineNetwork implements OfflineNetwork {
  ApiOfflineNetwork(this._api, {HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final ApiClient _api;
  final HttpClient Function() _httpClientFactory;

  @override
  Future<Map<String, ChapterContent>> chaptersBatch(
    List<Chapter> chapters, {
    Duration timeout = const Duration(seconds: 40),
  }) => _api.chaptersBatch(chapters, timeout: timeout);

  @override
  Future<ChapterContent> chapter(String chapterId, {String title = ''}) =>
      _api.chapter(chapterId, title: title);

  @override
  Future<VideoSource> videoSource(String episodeId, {int? maxHeight}) =>
      _api.videoSource(episodeId, maxHeight: maxHeight);

  @override
  Future<OfflineVideoStream> openVideoStream(String url) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse(url));
      // 明文 mp4 不应被压缩；显式 identity 保证 content-length 与落盘字节一致。
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw ApiException('下载失败（HTTP ${response.statusCode}）');
      }
      final length = response.contentLength > 0 ? response.contentLength : null;
      return OfflineVideoStream(
        bytes: response,
        contentLength: length,
        close: () async => client.close(force: true),
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

/// 下载节奏/节流的可注入参数（测试里覆写成 0 让用例瞬时跑完）。
class OfflineDownloadSettings {
  const OfflineDownloadSettings({
    this.batchGap = const Duration(milliseconds: 200),
    this.retryDelay = const Duration(milliseconds: 500),
    this.progressInterval = const Duration(milliseconds: 200),
    this.manifestInterval = const Duration(seconds: 30),
  });

  /// 小说批次之间的间隔（避免连续高压请求上游）。
  final Duration batchGap;

  /// 短剧单集失败后的重试等待。
  final Duration retryDelay;

  /// 进度节流：state 最多这么频繁更新一次。
  final Duration progressInterval;

  /// manifest 落盘间隔（暂停/完成/取消时无条件落盘）。
  final Duration manifestInterval;
}

/// 进程级单任务下载器（小说整本 / 短剧整剧共用）。
///
/// 状态机：`null/idle → running → (paused | done | failed)`；`cancel` 直接清掉
/// 任务记录（已下载内容保留）。同一时刻只跑一个任务：已有任务在跑时新的
/// `start*` 进 FIFO 等待队列（[OfflineQueue]），当前任务完成/失败/取消后自动
/// 接上下一个；paused 时不接续（用户主动暂停不能偷偷下别的）。不新增自动重试
/// 循环：Rust 侧已有重试，这里只在"连续 N 章/集失败"时暂停并提示。
///
/// 前后台：`WidgetsBindingObserver` 监听；切后台在当前章/集结束后暂停并落盘，
/// 回前台**不自动继续**（只把状态改成 paused，由用户点继续）。纯 Dart 测试
/// 环境没有 WidgetsBinding 时静默跳过该能力。
final class OfflineDownloader extends Notifier<OfflineTask?> {
  /// 小说每批章数（内核 batch 接口建议 20 章/批）。
  static const int batchSize = 20;

  /// 开任务前的粗估：一章正文约 15KB。
  static const int novelChapterEstimateBytes = 15 * 1024;

  /// 连续失败多少章/集后暂停任务。
  static const int maxConsecutiveFailures = 3;

  /// 单集失败重试次数（不含首次）。
  static const int videoRetries = 1;

  _RunControl? _control;
  _LifecycleObserver? _observer;

  /// 正在启动、还没发布 running 快照的任务（入口占位）。
  ///
  /// start* 在设置 [_control] 之前要 await 恢复态和几个读盘动作，对上千章的书
  /// 这几个 `file.exists()` 可能花掉几十上百毫秒。期间用户再点一次（尤其详情
  /// 页按钮看起来「没反应」时）会同时通过 `_control == null` 检查、并发跑起
  /// 两份同一本书。入口先同步占位，第二次点击就会走队列而不是再开一个任务。
  OfflineQueueJob? _startingJob;

  /// 启动恢复的未来：start* 之前 await 它，避免"恢复态把新任务覆盖成 paused"
  /// 的启动竞态（恢复是 build 里的异步动作）。
  Future<void>? _restoreFuture;

  /// 暂停后可继续的任务入参（仅本进程内有效；重启后由页面重新调用 start
  /// 按文件缺口续传）。
  ({
    OfflineTaskKind kind,
    String id,
    String title,
    String cover,
    List<Chapter> items,
  })?
  _resumable;

  OfflineTaskStore get _taskStore => ref.read(offlineTaskStoreProvider);
  OfflineBookStore get _bookStore => ref.read(offlineBookStoreProvider);
  OfflineSeriesStore get _seriesStore => ref.read(offlineSeriesStoreProvider);
  OfflineNetwork get _network => ref.read(offlineNetworkProvider);
  OfflineDownloadSettings get _settings =>
      ref.read(offlineDownloadSettingsProvider);

  @override
  OfflineTask? build() {
    _attachLifecycleObserver();
    _restoreFuture = _restore();
    return null;
  }

  void _attachLifecycleObserver() {
    try {
      final observer = _LifecycleObserver(this);
      WidgetsBinding.instance.addObserver(observer);
      _observer = observer;
      ref.onDispose(() {
        final observer = _observer;
        if (observer != null) {
          WidgetsBinding.instance.removeObserver(observer);
          _observer = null;
        }
      });
    } catch (_) {
      // 纯 Dart 测试环境没有 WidgetsBinding：后台暂停不可用，其余逻辑正常。
    }
  }

  /// 启动恢复：持久化任务里的 running 一律降级成 paused（避免一进 App 就
  /// 偷偷下载），其余状态原样恢复给 UI 展示。
  Future<void> _restore() async {
    // 启动时先清掉上次崩溃残留的半截文件（只删 `.part`，不动正式内容）。
    await _bookStore.cleanupPartFiles();
    await _seriesStore.cleanupPartFiles();
    final stored = await _taskStore.read();
    if (stored == null) return;
    final restored = stored.isRunning
        ? stored.copyWith(
            status: OfflineTaskStatus.paused,
            error: '应用重启，任务已暂停',
            updatedAt: DateTime.now(),
          )
        : stored;
    await _taskStore.write(restored);
    _setState(restored);
  }

  // ---------------------------------------------------------------------------
  // 小说整本
  // ---------------------------------------------------------------------------

  Future<OfflineStartDisposition> startNovelBook({
    required String bookId,
    required String title,
    required String cover,
    required List<Chapter> chapters,
  }) async {
    if (bookId.isEmpty || chapters.isEmpty) {
      return OfflineStartDisposition.started;
    }
    final job = OfflineQueueJob(
      kind: OfflineTaskKind.novel,
      id: bookId,
      title: title,
      cover: cover,
      items: chapters,
    );
    // 入口同步占位：已有任务在跑、或另一个 start 还在启动中时，本次直接排队。
    if (_control != null || _startingJob != null) {
      return _enqueue(job);
    }
    _startingJob = job;
    try {
      await _restoreFuture;

      // 排队中的同一个任务被直接启动（典型场景：暂停期间用户又点了一次）：
      // 先把它从队列消费掉，否则本次跑完后 drain 会再把它启动一遍。
      ref
          .read(offlineQueueProvider.notifier)
          .remove(OfflineTaskKind.novel, bookId);

      final store = _bookStore;
      final existing = await store.read(bookId);
      final missing = await store.missingChapterIds(bookId, chapters);
      final stats = await store.stats();
      final estimate = missing.length * novelChapterEstimateBytes;
      if (stats.bytes + estimate > OfflineBookStore.novelCapBytes) {
        throw OfflineQuotaExceeded(
          kind: OfflineTaskKind.novel,
          usedBytes: stats.bytes,
          capBytes: OfflineBookStore.novelCapBytes,
        );
      }

      final now = DateTime.now();
      final manifest = OfflineBook(
        bookId: bookId,
        title: title.isNotEmpty ? title : (existing?.title ?? ''),
        cover: cover.isNotEmpty ? cover : (existing?.cover ?? ''),
        chapters: [
          for (var i = 0; i < chapters.length; i++)
            OfflineChapter(
              id: chapters[i].id,
              title: chapters[i].title,
              volumeName: chapters[i].volumeName,
              index: i,
            ),
        ],
        completed: chapters.length - missing.length,
        bytes: existing?.bytes ?? 0,
        createdAt: existing?.createdAt,
        updatedAt: now,
      );
      await store.begin(manifest);

      final control = _RunControl();
      _control = control;
      final task = OfflineTask(
        kind: OfflineTaskKind.novel,
        id: bookId,
        title: manifest.title,
        cover: manifest.cover,
        completed: manifest.completed,
        total: manifest.total,
        bytes: manifest.bytes,
        status: OfflineTaskStatus.running,
        updatedAt: now,
      );
      await _publish(task);
      _resumable = null;

      try {
        final result = await _runNovel(
          bookStore: store,
          chapters: chapters,
          missing: missing.toSet(),
          manifest: manifest,
          control: control,
        );
        await _finishNovel(
          result: result,
          id: bookId,
          chapters: chapters,
          title: manifest.title,
          cover: manifest.cover,
        );
      } catch (error) {
        await _failTask(
          kind: OfflineTaskKind.novel,
          id: bookId,
          title: manifest.title,
          cover: manifest.cover,
          error: error,
        );
        rethrow;
      } finally {
        _control = null;
        control.done.complete();
      }
      return OfflineStartDisposition.started;
    } finally {
      // 先释放入口占位再 drain：否则 drain 里的 start 会把自己当成「并发启动」
      // 而重新入队。
      if (identical(_startingJob, job)) _startingJob = null;
      unawaited(_drainQueue());
    }
  }

  Future<_RunResult> _runNovel({
    required OfflineBookStore bookStore,
    required List<Chapter> chapters,
    required Set<String> missing,
    required OfflineBook manifest,
    required _RunControl control,
  }) async {
    final settings = _settings;
    final network = _network;
    final pending = [
      for (final chapter in chapters)
        if (missing.contains(chapter.id)) chapter,
    ];
    final failed = <String>{};
    String? firstError;
    var completed = manifest.completed;
    var bytes = manifest.bytes;
    var consecutive = 0;
    var index = 0;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    var lastFlush = DateTime.now();
    final meter = _SpeedMeter();

    Future<void> flush({bool force = false}) async {
      final next = manifest.copyWith(
        completed: completed,
        bytes: bytes,
        updatedAt: DateTime.now(),
      );
      if (!force &&
          DateTime.now().difference(lastFlush) < settings.manifestInterval) {
        return;
      }
      lastFlush = DateTime.now();
      await bookStore.saveManifest(next);
    }

    void emit() {
      _setState(
        OfflineTask(
          kind: OfflineTaskKind.novel,
          id: manifest.bookId,
          title: manifest.title,
          cover: manifest.cover,
          completed: completed,
          total: manifest.total,
          bytes: bytes,
          // 网速是瞬态值：只在 running 的 emit 里带，收尾状态一律归 0。
          speedBytesPerSecond: meter.bps,
          status: OfflineTaskStatus.running,
          updatedAt: DateTime.now(),
        ),
      );
    }

    while (index < pending.length) {
      if (control.stopRequested) break;
      if (consecutive >= maxConsecutiveFailures) {
        control.pauseMessage ??= '网络异常，任务已暂停';
        control.pauseRequested = true;
        break;
      }
      final end = (index + batchSize).clamp(0, pending.length);
      final batch = pending.sublist(index, end);
      index = end;

      var fromBatch = const <String, ChapterContent>{};
      try {
        fromBatch = await network.chaptersBatch(batch);
      } catch (_) {
        // 整批失败：下面逐章回退单章接口，不把整批算失败。
        fromBatch = const {};
      }
      if (control.stopRequested) break;

      for (final chapter in batch) {
        if (control.stopRequested) break;
        if (control.backgroundPauseRequested) {
          control.pauseMessage ??= '切到后台，任务已暂停';
          control.pauseRequested = true;
          break;
        }
        if (consecutive >= maxConsecutiveFailures) {
          control.pauseMessage ??= '网络异常，任务已暂停';
          control.pauseRequested = true;
          break;
        }

        var content = fromBatch[chapter.id];
        if (content != null) {
          content = _withChapterTitle(content, chapter.title);
        }
        if (content == null || content.paragraphs.isEmpty) {
          content = await _fetchSingleChapter(network, chapter);
        }
        if (content == null) {
          firstError ??= '第 ${chapter.index + 1} 章拉取失败';
          unawaited(
            offlineDiag(
              'novel fail book=${manifest.bookId} chapter=${chapter.id}',
            ),
          );
          failed.add(chapter.id);
          consecutive += 1;
          continue;
        }
        try {
          bytes += await bookStore.writeChapter(manifest.bookId, content);
          completed += 1;
          consecutive = 0;
          // 一章一次采样：小说批量下载的节奏比视频粗，用累计 bytes 算瞬时速度。
          meter.sample(bytes, DateTime.now());
        } catch (error) {
          // 磁盘写失败按单章失败处理：连续失败会暂停任务并提示。
          firstError ??= '第 ${chapter.index + 1} 章写入失败：${_briefError(error)}';
          unawaited(
            offlineDiag(
              'novel write fail book=${manifest.bookId} chapter=${chapter.id} '
              'error=${_briefError(error)}',
            ),
          );
          failed.add(chapter.id);
          consecutive += 1;
          continue;
        }
        final now = DateTime.now();
        if (now.difference(lastProgress) >= settings.progressInterval) {
          lastProgress = now;
          emit();
        }
        await flush();
      }
      if (control.stopRequested) break;
      if (index < pending.length) await Future<void>.delayed(settings.batchGap);
    }

    await flush(force: true);
    return _RunResult(
      completed: completed,
      bytes: bytes,
      cancelled: control.cancelRequested,
      paused: control.pauseRequested,
      message:
          control.pauseMessage ??
          (failed.isEmpty ? null : '有 ${failed.length} 章下载失败，可点继续重试'),
      firstError: firstError,
    );
  }

  Future<ChapterContent?> _fetchSingleChapter(
    OfflineNetwork network,
    Chapter chapter,
  ) async {
    try {
      final content = await network.chapter(chapter.id, title: chapter.title);
      if (content.paragraphs.isEmpty) return null;
      return _withChapterTitle(content, chapter.title);
    } catch (_) {
      return null;
    }
  }

  ChapterContent _withChapterTitle(ChapterContent content, String title) {
    if (content.title.isNotEmpty || title.isEmpty) return content;
    return ChapterContent(
      id: content.id,
      title: title,
      paragraphs: content.paragraphs,
    );
  }

  Future<void> _finishNovel({
    required _RunResult result,
    required String id,
    required List<Chapter> chapters,
    required String title,
    required String cover,
  }) async {
    if (result.cancelled) {
      await _taskStore.clear();
      _setState(null);
      _resumable = null;
      _invalidateOfflineProviders(OfflineTaskKind.novel, id);
      return;
    }
    // 有失败章 = 没下完：按 paused 收尾（可继续补齐），不能标 done。
    final complete = result.completed >= chapters.length;
    final task = OfflineTask(
      kind: OfflineTaskKind.novel,
      id: id,
      title: title,
      cover: cover,
      completed: result.completed,
      total: chapters.length,
      bytes: result.bytes,
      // 收尾状态不保留运行中的网速。
      speedBytesPerSecond: 0,
      status: (result.paused || !complete)
          ? OfflineTaskStatus.paused
          : OfflineTaskStatus.done,
      error: _errorWithDetail(result),
      updatedAt: DateTime.now(),
    );
    if (task.isPaused) {
      _resumable = (
        kind: OfflineTaskKind.novel,
        id: task.id,
        title: title,
        cover: cover,
        items: chapters,
      );
    } else {
      _resumable = null;
    }
    await _publish(task);
    _invalidateOfflineProviders(OfflineTaskKind.novel, task.id);
  }

  // ---------------------------------------------------------------------------
  // 短剧整剧
  // ---------------------------------------------------------------------------

  Future<OfflineStartDisposition> startVideoSeries({
    required String seriesId,
    required String title,
    required String cover,
    required List<Chapter> episodes,
  }) async {
    if (seriesId.isEmpty || episodes.isEmpty) {
      return OfflineStartDisposition.started;
    }
    final job = OfflineQueueJob(
      kind: OfflineTaskKind.video,
      id: seriesId,
      title: title,
      cover: cover,
      items: episodes,
    );
    // 入口同步占位：已有任务在跑、或另一个 start 还在启动中时，本次直接排队。
    if (_control != null || _startingJob != null) {
      return _enqueue(job);
    }
    _startingJob = job;
    try {
      await _restoreFuture;

      // 排队中的同一部剧被直接启动：先消费掉队列项，避免跑完后再重跑一遍。
      ref
          .read(offlineQueueProvider.notifier)
          .remove(OfflineTaskKind.video, seriesId);

      final store = _seriesStore;
      final existing = await store.read(seriesId);
      final missing = await store.missingEpisodeIds(seriesId, episodes);
      // 短剧单集体积差异大（几十 MB 到几百 MB），不能用「集数 × 固定估算」在开始时
      // 一刀切：一部 40 集的剧按 150MB/集估会直接超过 3GiB 上限，表现为刚点下载
      // 就报「空间不足」。这里只挡「区已经满了」的情况，下载过程中逐集检查额度。
      final stats = await store.stats();
      if (stats.bytes >= store.capBytes) {
        throw OfflineQuotaExceeded(
          kind: OfflineTaskKind.video,
          usedBytes: stats.bytes,
          capBytes: store.capBytes,
        );
      }

      final now = DateTime.now();
      // 本次下载的清晰度上限（默认 720P）：整剧按同一口径取流；已下载集的
      // 实际档位从旧 manifest 继承，避免重下/续传时丢清晰度信息。
      final downloadQuality = ref.read(videoDownloadQualityProvider);
      final existingEpisodes = {
        for (final episode in existing?.episodes ?? const <OfflineEpisode>[])
          episode.id: episode,
      };
      final manifest = OfflineSeries(
        seriesId: seriesId,
        title: title.isNotEmpty ? title : (existing?.title ?? ''),
        cover: cover.isNotEmpty ? cover : (existing?.cover ?? ''),
        episodes: [
          for (var i = 0; i < episodes.length; i++)
            OfflineEpisode(
              id: episodes[i].id,
              title: episodes[i].title,
              index: i,
              bytes: existingEpisodes[episodes[i].id]?.bytes ?? 0,
              cached: existingEpisodes[episodes[i].id]?.cached ?? false,
              variantName: existingEpisodes[episodes[i].id]?.variantName ?? '',
              shortEdge: existingEpisodes[episodes[i].id]?.shortEdge ?? 0,
            ),
        ],
        completed: episodes.length - missing.length,
        bytes: existing?.bytes ?? 0,
        qualityMaxHeight: downloadQuality.maxHeight,
        createdAt: existing?.createdAt,
        updatedAt: now,
      );
      await store.begin(manifest);

      final control = _RunControl();
      _control = control;
      final task = OfflineTask(
        kind: OfflineTaskKind.video,
        id: seriesId,
        title: manifest.title,
        cover: manifest.cover,
        completed: manifest.completed,
        total: manifest.total,
        bytes: manifest.bytes,
        status: OfflineTaskStatus.running,
        updatedAt: now,
      );
      await _publish(task);
      _resumable = null;

      try {
        final result = await _runVideo(
          seriesStore: store,
          episodes: episodes,
          missing: missing.toSet(),
          manifest: manifest,
          control: control,
        );
        await _finishVideo(
          result: result,
          id: seriesId,
          episodes: episodes,
          title: manifest.title,
          cover: manifest.cover,
        );
      } catch (error) {
        await _failTask(
          kind: OfflineTaskKind.video,
          id: seriesId,
          title: manifest.title,
          cover: manifest.cover,
          error: error,
        );
        rethrow;
      } finally {
        _control = null;
        control.done.complete();
      }
      return OfflineStartDisposition.started;
    } finally {
      // 先释放入口占位再 drain：否则 drain 里的 start 会把自己当成「并发启动」
      // 而重新入队。
      if (identical(_startingJob, job)) _startingJob = null;
      unawaited(_drainQueue());
    }
  }

  Future<_RunResult> _runVideo({
    required OfflineSeriesStore seriesStore,
    required List<Chapter> episodes,
    required Set<String> missing,
    required OfflineSeries manifest,
    required _RunControl control,
  }) async {
    final settings = _settings;
    final network = _network;
    final pending = [
      for (final episode in episodes)
        if (missing.contains(episode.id)) episode,
    ];
    final failed = <String>{};
    String? firstError;
    var completed = manifest.completed;
    var bytes = manifest.bytes;
    var consecutive = 0;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    var lastFlush = DateTime.now();
    final meter = _SpeedMeter();

    // 每集实际档位写回 manifest（旧数据/失败集保持原值）。
    final qualityEpisodes = manifest.episodes.toList();
    Future<void> flush({bool force = false}) async {
      final next = manifest.copyWith(
        completed: completed,
        bytes: bytes,
        episodes: qualityEpisodes,
        updatedAt: DateTime.now(),
      );
      if (!force &&
          DateTime.now().difference(lastFlush) < settings.manifestInterval) {
        return;
      }
      lastFlush = DateTime.now();
      await seriesStore.saveManifest(next);
    }

    void emit({int partialBytes = 0}) {
      _setState(
        OfflineTask(
          kind: OfflineTaskKind.video,
          id: manifest.seriesId,
          title: manifest.title,
          cover: manifest.cover,
          completed: completed,
          total: manifest.total,
          // 集内进度：已提交字节 + 当前集已收字节（仅展示用，不落 manifest）。
          bytes: bytes + partialBytes,
          // 网速是瞬态值：只在 running 的 emit 里带，收尾状态一律归 0。
          speedBytesPerSecond: meter.bps,
          status: OfflineTaskStatus.running,
          updatedAt: DateTime.now(),
        ),
      );
    }

    for (final episode in pending) {
      if (control.stopRequested) break;
      if (control.backgroundPauseRequested) {
        control.pauseMessage ??= '切到后台，任务已暂停';
        control.pauseRequested = true;
        break;
      }
      if (consecutive >= maxConsecutiveFailures) {
        control.pauseMessage ??= '网络异常，任务已暂停';
        control.pauseRequested = true;
        break;
      }
      // 软上限在下载过程中逐集检查：允许当前这一集把区间顶到上限（单集体积未知），
      // 到了上限就暂停并提示去清理，而不是在开始时就按估算拒绝整部剧。
      if (bytes >= seriesStore.capBytes) {
        control.pauseMessage ??=
            '离线区空间不足（已用 ${_formatBytesShort(bytes)} / 上限 '
            '${_formatBytesShort(seriesStore.capBytes)}），任务已暂停，'
            '请先在「我的 → 缓存」页删除不需要的缓存';
        control.pauseRequested = true;
        break;
      }

      var finished = false;
      var aborted = false;
      for (var attempt = 0; attempt <= videoRetries && !finished; attempt++) {
        File? part;
        IOSink? sink;
        OfflineVideoStream? stream;
        try {
          unawaited(
            offlineDiag(
              'video start series=${manifest.seriesId} episode=${episode.id}',
            ),
          );
          final source = await network.videoSource(
            episode.id,
            maxHeight: manifest.qualityMaxHeight > 0
                ? manifest.qualityMaxHeight
                : null,
          );
          if (!source.isValid) {
            throw ApiException('这一集没有可下载地址');
          }
          stream = await network.openVideoStream(source.url);
          part = await seriesStore.partFile(manifest.seriesId, episode.id);
          sink = part.openWrite();
          var received = 0;
          await for (final chunk in stream.bytes) {
            // 取消可以发生在集内：立即中止当前集，删 .part（已完成集保留）。
            if (control.cancelRequested) throw const _DownloadCancelled();
            sink.add(chunk);
            received += chunk.length;
            final now = DateTime.now();
            // 每个 chunk 采样一次（很便宜）：集合内字节进度算实时网速。
            meter.sample(bytes + received, now);
            if (now.difference(lastProgress) >= settings.progressInterval) {
              lastProgress = now;
              emit(partialBytes: received);
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
          await stream.close?.call();
          stream = null;
          await seriesStore.commitEpisode(
            manifest.seriesId,
            episode.id,
            bytes: received,
          );
          unawaited(
            offlineDiag(
              'video commit series=${manifest.seriesId} episode=${episode.id} '
              'bytes=$received',
            ),
          );
          bytes += received;
          completed += 1;
          consecutive = 0;
          final applied = source.appliedVariant;
          final qualityIndex = qualityEpisodes.indexWhere(
            (item) => item.id == episode.id,
          );
          if (qualityIndex >= 0) {
            qualityEpisodes[qualityIndex] = qualityEpisodes[qualityIndex]
                .copyWith(
                  bytes: received,
                  cached: true,
                  variantName: applied?.name ?? '',
                  shortEdge: applied?.shortEdge ?? 0,
                );
          }
          // 提交后再采一次，把累计口径从「已提交 + 集内已收」切回已提交。
          meter.sample(bytes, DateTime.now());
          finished = true;
        } on _DownloadCancelled {
          // 集内取消：清掉半截文件，不当成"失败集"计数。
          await _closeQuietly(sink);
          sink = null;
          await _closeStreamQuietly(stream);
          stream = null;
          if (part != null) {
            await seriesStore.deletePart(manifest.seriesId, episode.id);
          }
          aborted = true;
          break;
        } catch (error) {
          firstError ??= '第 ${episode.index + 1} 集：${_briefError(error)}';
          unawaited(
            offlineDiag(
              'video fail series=${manifest.seriesId} episode=${episode.id} '
              'attempt=$attempt error=${_briefError(error)}',
            ),
          );
          // 半截文件必须清掉，否则下次 resume 会被当成"已缓存"。
          await _closeQuietly(sink);
          sink = null;
          await _closeStreamQuietly(stream);
          stream = null;
          if (part != null) {
            await seriesStore.deletePart(manifest.seriesId, episode.id);
          }
          if (attempt >= videoRetries) break;
          await Future<void>.delayed(settings.retryDelay);
        }
      }

      if (aborted) break;
      if (!finished) {
        failed.add(episode.id);
        consecutive += 1;
        continue;
      }
      emit();
      await flush();
    }

    // 最终 manifest 以本轮的累计值落盘（暂停/取消也保留已完成集）。
    await flush(force: true);
    return _RunResult(
      completed: completed,
      bytes: bytes,
      cancelled: control.cancelRequested,
      paused: control.pauseRequested,
      message:
          control.pauseMessage ??
          (failed.isEmpty ? null : '有 ${failed.length} 集下载失败，可点继续重试'),
      firstError: firstError,
    );
  }

  Future<void> _finishVideo({
    required _RunResult result,
    required String id,
    required List<Chapter> episodes,
    required String title,
    required String cover,
  }) async {
    if (result.cancelled) {
      await _taskStore.clear();
      _setState(null);
      _resumable = null;
      _invalidateOfflineProviders(OfflineTaskKind.video, id);
      return;
    }
    // 有失败集 = 没下完：按 paused 收尾（可继续补齐），不能标 done。
    final complete = result.completed >= episodes.length;
    final task = OfflineTask(
      kind: OfflineTaskKind.video,
      id: id,
      title: title,
      cover: cover,
      completed: result.completed,
      total: episodes.length,
      bytes: result.bytes,
      // 收尾状态不保留运行中的网速。
      speedBytesPerSecond: 0,
      status: (result.paused || !complete)
          ? OfflineTaskStatus.paused
          : OfflineTaskStatus.done,
      error: _errorWithDetail(result),
      updatedAt: DateTime.now(),
    );
    if (task.isPaused) {
      _resumable = (
        kind: OfflineTaskKind.video,
        id: task.id,
        title: title,
        cover: cover,
        items: episodes,
      );
    } else {
      _resumable = null;
    }
    await _publish(task);
    _invalidateOfflineProviders(OfflineTaskKind.video, task.id);
  }

  // ---------------------------------------------------------------------------
  // 控制：暂停 / 继续 / 取消 / 删除
  // ---------------------------------------------------------------------------

  /// 暂停：当前章/集结束后停（不中断批次/单集流），进度落盘。
  Future<void> pause() async {
    final control = _control;
    if (control != null) {
      control.pauseRequested = true;
      control.pauseMessage ??= '任务已暂停';
      return;
    }
    final current = state;
    if (current == null || !current.isRunning) return;
    final paused = current.copyWith(
      status: OfflineTaskStatus.paused,
      // copyWith 会透传旧字段，这里显式把运行中的网速清掉。
      speedBytesPerSecond: 0,
      error: '任务已暂停',
      updatedAt: DateTime.now(),
    );
    await _publish(paused);
  }

  /// 继续本进程内被暂停的任务。
  ///
  /// 进程重启后 `_resumable` 已丢失：此时页面应重新调用 `startNovelBook` /
  /// `startVideoSeries`（幂等，按文件缺口续传），所以这里对恢复态任务是 no-op。
  /// 返回是否真的续传了：false = 没有本进程内可继续的任务（例如进程重启后
  /// 只剩持久化的 paused 任务），调用方应重新调用 start*（幂等）。
  Future<bool> resume() async {
    final resumable = _resumable;
    // 有任务在跑/正在启动时不能续传（start* 会被排进队列）。
    if (_control != null || _startingJob != null || resumable == null) {
      return false;
    }
    switch (resumable.kind) {
      case OfflineTaskKind.novel:
        await startNovelBook(
          bookId: resumable.id,
          title: resumable.title,
          cover: resumable.cover,
          chapters: resumable.items,
        );
      case OfflineTaskKind.video:
        await startVideoSeries(
          seriesId: resumable.id,
          title: resumable.title,
          cover: resumable.cover,
          episodes: resumable.items,
        );
    }
    return true;
  }

  /// 取消：保留已完成内容（manifest 已按进度落盘），清掉任务记录。
  Future<void> cancel() async {
    final control = _control;
    if (control != null) {
      control.cancelRequested = true;
      await control.done.future;
      return;
    }
    final current = state;
    if (current == null) return;
    await _taskStore.clear();
    _setState(null);
    _resumable = null;
    _invalidateOfflineProviders(current.kind, current.id);
    // 取消当前任务后接着跑队列里的下一个（用户取消 = 不想要这个，不是停整条队列）。
    unawaited(_drainQueue());
  }

  /// 删除某本书/某部剧：先取消它正在跑的任务，再删离线内容与任务记录。
  Future<void> clearFor(OfflineTaskKind kind, String id) async {
    // 还在队列里等待的同一本/同一部剧：直接取消排队，避免删完又被自动开始。
    ref.read(offlineQueueProvider.notifier).remove(kind, id);
    final current = state;
    if (current != null && current.kind == kind && current.id == id) {
      if (_control != null) {
        await cancel();
      } else {
        await _taskStore.clear();
        _setState(null);
      }
    }
    switch (kind) {
      case OfflineTaskKind.novel:
        await _bookStore.delete(id);
      case OfflineTaskKind.video:
        await _seriesStore.delete(id);
    }
    _resumable = null;
    _invalidateOfflineProviders(kind, id);
  }

  // ---------------------------------------------------------------------------
  // 队列
  // ---------------------------------------------------------------------------

  /// 防止多个收尾路径同时 drain（start 的 finally、cancel、删除都可能触发）。
  bool _draining = false;

  /// 把新任务排进等待队列。当前正在跑的就是同一本/同一部剧时不再重复入队
  /// （用户重复点「缓存」不该出现两条相同记录）；同一本正在启动（入口占位）
  /// 时同理。
  OfflineStartDisposition _enqueue(OfflineQueueJob job) {
    final running = state;
    final starting = _startingJob;
    final sameRunning =
        running != null && running.kind == job.kind && running.id == job.id;
    final sameStarting =
        starting != null && starting.kind == job.kind && starting.id == job.id;
    if (!sameRunning && !sameStarting) {
      ref.read(offlineQueueProvider.notifier).enqueue(job);
    }
    return OfflineStartDisposition.queued;
  }

  /// 当前任务收尾后自动启动队列里的下一个。
  ///
  /// 只在「完成 / 失败 / 取消」后继续；paused（用户主动暂停或切后台）时停在
  /// 队列里——用户以为暂停了却偷偷下别的会很怪。
  Future<void> _drainQueue() async {
    if (_draining) return;
    _draining = true;
    try {
      // 正在启动（入口占位）时不抢跑：那个 start 的 finally 会再触发一次 drain。
      while (_control == null && _startingJob == null) {
        final current = state;
        if (current != null && current.isPaused) return;
        final job = ref.read(offlineQueueProvider.notifier).takeFirst();
        if (job == null) return;
        // 记录启动前的 state 引用：start* 运行期失败会先发布一条新的 failed
        // 快照再 rethrow，用它区分「已经发布过失败快照」与「启动前就失败」。
        final before = state;
        try {
          switch (job.kind) {
            case OfflineTaskKind.novel:
              await startNovelBook(
                bookId: job.id,
                title: job.title,
                cover: job.cover,
                chapters: job.items,
              );
            case OfflineTaskKind.video:
              await startVideoSeries(
                seriesId: job.id,
                title: job.title,
                cover: job.cover,
                episodes: job.items,
              );
          }
        } catch (error) {
          // 队列任务启动就失败（额度/写盘等）：发布一条失败任务让用户在缓存
          // 中心看到原因，然后继续下一个，不让一个坏任务堵死整条队列。
          //
          // start* 在「运行期」失败时已经发布过同一条 failed 快照再 rethrow，
          // 这里不能再发一次（一次失败两条 failed、重复失效 provider）。
          final current = state;
          final publishedFailure =
              !identical(current, before) &&
              current != null &&
              current.kind == job.kind &&
              current.id == job.id &&
              current.status == OfflineTaskStatus.failed;
          if (!publishedFailure) {
            await _failTask(
              kind: job.kind,
              id: job.id,
              title: job.title,
              cover: job.cover,
              error: error,
            );
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  Future<void> _publish(OfflineTask task) async {
    await _taskStore.write(task);
    _setState(task);
  }

  Future<void> _failTask({
    required OfflineTaskKind kind,
    required String id,
    required String title,
    required String cover,
    required Object error,
  }) async {
    // 只有「state 就是同一个任务」时才继承进度。队列任务在启动前失败时，
    // state 还是上一个任务的收尾快照，把它的 completed/total/bytes 搬过来
    // 会让缓存中心把 B 的失败显示成 A 的进度。
    final snapshot = state;
    final sameTask =
        snapshot != null && snapshot.kind == kind && snapshot.id == id
        ? snapshot
        : null;
    final task = OfflineTask(
      kind: kind,
      id: id,
      title: title,
      cover: cover,
      completed: sameTask?.completed ?? 0,
      total: sameTask?.total ?? 0,
      bytes: sameTask?.bytes ?? 0,
      // 失败任务不保留运行中的网速。
      speedBytesPerSecond: 0,
      status: OfflineTaskStatus.failed,
      error: apiErrorCopy(error, fallback: '离线缓存失败，请重试'),
      updatedAt: DateTime.now(),
    );
    await _publish(task);
    _invalidateOfflineProviders(kind, id);
  }

  void _setState(OfflineTask? task) {
    try {
      state = task;
    } catch (_) {
      // Provider 已释放（页面退出/容器销毁）：晚到的异步结果直接丢弃。
    }
  }

  /// 离线列表/统计变化后失效相关 provider（页面 watch 它们刷新）。
  void _invalidateOfflineProviders(OfflineTaskKind kind, String id) {
    if (kind == OfflineTaskKind.novel) {
      ref.invalidate(offlineNovelStatsProvider);
      ref.invalidate(offlineNovelListProvider);
      if (id.isNotEmpty) ref.invalidate(offlineNovelProvider(id));
    } else {
      ref.invalidate(offlineVideoStatsProvider);
      ref.invalidate(offlineVideoListProvider);
      if (id.isNotEmpty) ref.invalidate(offlineSeriesProvider(id));
    }
  }

  void _onLifecycle(AppLifecycleState lifecycle) {
    final control = _control;
    if (control == null) return;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      control.backgroundPauseRequested = true;
    }
  }

  @visibleForTesting
  void handleAppLifecycleForTest(AppLifecycleState lifecycle) =>
      _onLifecycle(lifecycle);
}

/// 下载速度采样器：累计字节差 / 时间差，再用 EMA 平滑。
///
/// 单次采样（尤其小说一章）跨度大、瞬时值抖动；`0.7×旧 + 0.3×新` 的指数
/// 滑动平均让缓存中心页的「网速」更稳。首个样本只记基准（没有时间差），
/// 间隔 <=0ms 或字节回绕时不动 EMA，避免除零/跳动。
class _SpeedMeter {
  DateTime? _lastTime;
  int _lastBytes = 0;
  double _ema = 0;

  /// 最近一次平滑后的速度（字节/秒）。
  int get bps => _ema.round();

  void reset() {
    _lastTime = null;
    _lastBytes = 0;
    _ema = 0;
  }

  void sample(int totalBytes, DateTime now) {
    final lastTime = _lastTime;
    final lastBytes = _lastBytes;
    _lastTime = now;
    _lastBytes = totalBytes;
    if (lastTime == null) return;
    final elapsedMs = now.difference(lastTime).inMilliseconds;
    if (elapsedMs <= 0) return;
    if (totalBytes < lastBytes) return;
    final instant = (totalBytes - lastBytes) * 1000 / elapsedMs;
    _ema = _ema == 0 ? instant : _ema * 0.7 + instant * 0.3;
  }
}

/// 集内取消：只用于从流式下载的中途跳出，不当成失败。
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// 暂停/恢复期间的共享控制位。
class _RunControl {
  bool pauseRequested = false;
  bool cancelRequested = false;

  /// 切后台触发：当前章/集结束后暂停。
  bool backgroundPauseRequested = false;
  String? pauseMessage;
  final Completer<void> done = Completer<void>();

  bool get stopRequested => pauseRequested || cancelRequested;
}

/// 一次下载的收尾结果。
class _RunResult {
  const _RunResult({
    required this.completed,
    required this.bytes,
    required this.cancelled,
    required this.paused,
    this.message,
    this.firstError,
  });

  final int completed;
  final int bytes;
  final bool cancelled;
  final bool paused;
  final String? message;

  /// 本轮第一个失败的原始错误（展示/诊断用；连续失败暂停时带给用户看）。
  final String? firstError;
}

/// 前后台监听：切后台只打标记，由下载循环在章/集边界暂停。
class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._downloader);

  final OfflineDownloader _downloader;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _downloader._onLifecycle(state);
}

Future<void> _closeQuietly(IOSink? sink) async {
  if (sink == null) return;
  try {
    await sink.close();
  } catch (_) {
    // 已有异常在飞，关闭失败不再抛。
  }
}

Future<void> _closeStreamQuietly(OfflineVideoStream? stream) async {
  try {
    await stream?.close?.call();
  } catch (_) {
    // 同上。
  }
}

/// 下载器内部提示用的字节格式（不依赖 UI 层）。
String _formatBytesShort(int bytes) {
  final gb = 1024 * 1024 * 1024;
  final mb = 1024 * 1024;
  final kb = 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

/// 把任务的用户可读文案 + 第一条失败原因拼在一起（诊断/继续时能看到具体原因）。
String? _errorWithDetail(_RunResult result) {
  final message = result.message;
  final detail = result.firstError;
  if (detail == null || detail.isEmpty) return message;
  if (message == null || message.isEmpty) return detail;
  if (message.contains(detail)) return message;
  return '$message（$detail）';
}

/// 失败原因的简短展示：ApiException 用 message，其它异常截断 toString。
String _briefError(Object? error) {
  final text = error is ApiException
      ? error.message
      : (error?.toString() ?? '');
  return text.length <= 120 ? text : '${text.substring(0, 120)}…';
}
