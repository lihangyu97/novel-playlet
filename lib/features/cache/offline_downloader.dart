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

/// 已有任务在跑：单任务队列，后启动的任务直接提示（不排队）。
class OfflineTaskBusyException implements Exception {
  const OfflineTaskBusyException(this.current);

  /// 当前进行中的任务（可能为 null：任务刚启动还没发布状态）。
  final OfflineTask? current;

  @override
  String toString() => 'OfflineTaskBusyException(${current?.title})';
}

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
  Future<VideoSource> videoSource(String episodeId);

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
  Future<VideoSource> videoSource(String episodeId) =>
      _api.videoSource(episodeId);

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
/// 任务记录（已下载内容保留）。同一时刻只跑一个任务（后启动的抛
/// [OfflineTaskBusyException]）。不新增自动重试循环：Rust 侧已有重试，这里只
/// 在"连续 N 章/集失败"时暂停并提示。
///
/// 前后台：`WidgetsBindingObserver` 监听；切后台在当前章/集结束后暂停并落盘，
/// 回前台**不自动继续**（只把状态改成 paused，由用户点继续）。纯 Dart 测试
/// 环境没有 WidgetsBinding 时静默跳过该能力。
final class OfflineDownloader extends Notifier<OfflineTask?> {
  /// 小说每批章数（内核 batch 接口建议 20 章/批）。
  static const int batchSize = 20;

  /// 开任务前的粗估：一章正文约 15KB。
  static const int novelChapterEstimateBytes = 15 * 1024;

  /// 一集短剧约 150MB（软上限判断用，宁可估大）。
  static const int videoEpisodeEstimateBytes = 150 * 1024 * 1024;

  /// 连续失败多少章/集后暂停任务。
  static const int maxConsecutiveFailures = 3;

  /// 单集失败重试次数（不含首次）。
  static const int videoRetries = 1;

  _RunControl? _control;
  _LifecycleObserver? _observer;

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

  Future<void> startNovelBook({
    required String bookId,
    required String title,
    required String cover,
    required List<Chapter> chapters,
  }) async {
    if (bookId.isEmpty || chapters.isEmpty) return;
    await _restoreFuture;
    if (_control != null) throw OfflineTaskBusyException(state);

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
    var completed = manifest.completed;
    var bytes = manifest.bytes;
    var consecutive = 0;
    var index = 0;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    var lastFlush = DateTime.now();

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
          failed.add(chapter.id);
          consecutive += 1;
          continue;
        }
        try {
          bytes += await bookStore.writeChapter(manifest.bookId, content);
          completed += 1;
          consecutive = 0;
        } catch (_) {
          // 磁盘写失败按单章失败处理：连续失败会暂停任务并提示。
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
      status: (result.paused || !complete)
          ? OfflineTaskStatus.paused
          : OfflineTaskStatus.done,
      error: result.message,
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

  Future<void> startVideoSeries({
    required String seriesId,
    required String title,
    required String cover,
    required List<Chapter> episodes,
  }) async {
    if (seriesId.isEmpty || episodes.isEmpty) return;
    await _restoreFuture;
    if (_control != null) throw OfflineTaskBusyException(state);

    final store = _seriesStore;
    final existing = await store.read(seriesId);
    final missing = await store.missingEpisodeIds(seriesId, episodes);
    final stats = await store.stats();
    final estimate = missing.length * videoEpisodeEstimateBytes;
    if (stats.bytes + estimate > OfflineSeriesStore.videoCapBytes) {
      throw OfflineQuotaExceeded(
        kind: OfflineTaskKind.video,
        usedBytes: stats.bytes,
        capBytes: OfflineSeriesStore.videoCapBytes,
      );
    }

    final now = DateTime.now();
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
          ),
      ],
      completed: episodes.length - missing.length,
      bytes: existing?.bytes ?? 0,
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
    var completed = manifest.completed;
    var bytes = manifest.bytes;
    var consecutive = 0;
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    var lastFlush = DateTime.now();

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

      var finished = false;
      var aborted = false;
      for (var attempt = 0; attempt <= videoRetries && !finished; attempt++) {
        File? part;
        IOSink? sink;
        OfflineVideoStream? stream;
        try {
          final source = await network.videoSource(episode.id);
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
          bytes += received;
          completed += 1;
          consecutive = 0;
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
        } catch (_) {
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
      status: (result.paused || !complete)
          ? OfflineTaskStatus.paused
          : OfflineTaskStatus.done,
      error: result.message,
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
    if (_control != null || resumable == null) return false;
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
  }

  /// 删除某本书/某部剧：先取消它正在跑的任务，再删离线内容与任务记录。
  Future<void> clearFor(OfflineTaskKind kind, String id) async {
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
    final task = OfflineTask(
      kind: kind,
      id: id,
      title: title,
      cover: cover,
      completed: state?.completed ?? 0,
      total: state?.total ?? 0,
      bytes: state?.bytes ?? 0,
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
  });

  final int completed;
  final int bytes;
  final bool cancelled;
  final bool paused;
  final String? message;
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
