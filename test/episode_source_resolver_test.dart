import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/features/video/episode_source_resolver.dart';
import 'package:novel_playlet/features/video/playback_failure.dart';

/// 一次 resolve 的可观测副作用（记录每个回调被调用的次数与顺序）。
class Harness {
  Harness({
    this.offlineFile,
    this.prefetchedUrl,
    this.cachedUrl,
    this.cachedThrows = false,
    this.suspectedOffline = false,
    this.streamUrl = 'http://127.0.0.1:18931/src/stream.mp4',
    this.fullUrl = 'http://127.0.0.1:18931/src/full.mp4',
    this.streamThrows = false,
    this.playThrows,
  });

  final File? offlineFile;
  final String? prefetchedUrl;
  final String? cachedUrl;
  final bool cachedThrows;
  final bool suspectedOffline;
  final String streamUrl;
  final String fullUrl;
  final bool streamThrows;

  /// 起播第 N 个网络地址（0 起）时抛出的错误；null = 正常起播。
  final Object? Function(int attempt)? playThrows;

  int offlineCalls = 0;
  int prefetchTakeCalls = 0;
  int cachedCalls = 0;
  int streamCalls = 0;
  int fullCalls = 0;
  int successCalls = 0;
  final List<String> played = <String>[];
  final List<bool> refreshFlags = <bool>[];

  EpisodeSourceResolver resolver({bool Function()? isCancelled}) =>
      EpisodeSourceResolver(
        loadOfflineFile: (episodeId, {required refresh}) async {
          offlineCalls += 1;
          return offlineFile;
        },
        takePrefetchedUrl: (episodeId) {
          prefetchTakeCalls += 1;
          return prefetchedUrl;
        },
        probeCachedUrl: (episodeId) async {
          cachedCalls += 1;
          if (cachedThrows) throw StateError('probe failed');
          return cachedUrl;
        },
        fetchSource: (episodeId, {required stream, required refresh}) async {
          refreshFlags.add(refresh);
          if (stream) {
            streamCalls += 1;
            if (streamThrows) throw ApiExceptionLike('stream 不可用');
            return VideoSource(url: streamUrl, streaming: true);
          }
          fullCalls += 1;
          return VideoSource(url: fullUrl);
        },
        isSuspectedOffline: () => suspectedOffline,
        recordSuccess: () => successCalls += 1,
        isCancelled: isCancelled,
      );

  Future<void> play(String url) async {
    final error = playThrows?.call(played.length);
    played.add(url);
    if (error != null) throw error;
  }
}

/// stream 取流失败的替身（避免依赖具体 ApiException 类型语义）。
class ApiExceptionLike implements Exception {
  ApiExceptionLike(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 取流级联（离线 → 预取 → 内核 cached → stream → 整集下载）的纯 Dart 测试。
///
/// 这套顺序原来在播放页里有三份实现（正式起播 / 翻页预热 / 下一集预取），
/// 现在由 [EpisodeSourceResolver] 统一。所有 IO 都是注入回调，这里逐条锁住
/// 回落分支和「哪些情况不能回退」（refresh、回环 connect refused、主动跳过）。
void main() {
  test('离线命中：返回本地文件，不探缓存/不取流/不起播', () async {
    final file = File('/tmp/episode.mp4');
    final harness = Harness(offlineFile: file);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved, isNotNull);
    expect(resolved!.isLocal, isTrue);
    expect(resolved.file!.path, file.path);
    expect(resolved.origin, EpisodeSourceOrigin.offlineFile);
    expect(harness.cachedCalls, 0);
    expect(harness.streamCalls, 0);
    expect(harness.fullCalls, 0);
    expect(harness.played, isEmpty);
  });

  test('refresh=true：跳过预取/内核缓存/stream，直接整集重取', () async {
    final harness = Harness(
      prefetchedUrl: 'http://127.0.0.1:18931/src/prefetched.mp4',
      cachedUrl: 'http://127.0.0.1:18931/src/cached.mp4',
    );

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      refresh: true,
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.fullDownload);
    expect(resolved.url, harness.fullUrl);
    expect(harness.cachedCalls, 0, reason: 'refresh 不应再探内核缓存');
    expect(harness.streamCalls, 0, reason: 'refresh 不应再试 stream');
    expect(
      harness.prefetchTakeCalls,
      1,
      reason: 'refresh 也要消费掉预取地址，避免旧 /src 留在页内 LRU 被误用',
    );
    expect(harness.fullCalls, 1);
    expect(harness.refreshFlags, <bool>[true], reason: '整集取流要带 refresh=true');
    expect(harness.played, <String>[harness.fullUrl]);
  });

  test('预取命中：直接起播预取地址，不探缓存也不再取流', () async {
    const prefetched = 'http://127.0.0.1:18931/src/prefetched.mp4';
    final harness = Harness(prefetchedUrl: prefetched);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.prefetched);
    expect(harness.played, <String>[prefetched]);
    expect(harness.cachedCalls, 0);
    expect(harness.streamCalls, 0);
  });

  test('预取地址起播失败（普通错误）：回退内核缓存，再回退取流', () async {
    const prefetched = 'http://127.0.0.1:18931/src/prefetched.mp4';
    const cached = 'http://127.0.0.1:18931/src/cached.mp4';
    final harness = Harness(
      prefetchedUrl: prefetched,
      cachedUrl: cached,
      playThrows: (attempt) => attempt == 0 ? StateError('预取已过期') : null,
    );

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.kernelCache);
    expect(harness.played, <String>[prefetched, cached]);
    expect(harness.streamCalls, 0, reason: '缓存命中后不该再取流');
  });

  test('预取地址回环 connect refused：直接抛出，不回退（换地址也播不了）', () async {
    final harness = Harness(
      prefetchedUrl: 'http://127.0.0.1:18931/src/prefetched.mp4',
      cachedUrl: 'http://127.0.0.1:18931/src/cached.mp4',
      playThrows: (attempt) => attempt == 0
          ? PlatformException(
              code: 'VideoError',
              message: 'Could not connect to the server.',
            )
          : null,
    );

    await expectLater(
      harness.resolver().resolve(episodeId: 'e1', playNetworkUrl: harness.play),
      throwsA(predicate(isLoopbackConnectRefused)),
    );
    expect(harness.played, hasLength(1));
    expect(harness.cachedCalls, 0, reason: '回环失败不应再探测/回退');
  });

  test('内核缓存命中：起播 cached 地址，不请求上游', () async {
    const cached = 'http://127.0.0.1:18931/src/cached.mp4';
    final harness = Harness(cachedUrl: cached);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.kernelCache);
    expect(harness.played, <String>[cached]);
    expect(harness.streamCalls, 0);
    expect(harness.fullCalls, 0);
  });

  test('内核缓存探测失败当 miss：继续走 stream', () async {
    final harness = Harness(cachedThrows: true);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.stream);
    expect(harness.streamCalls, 1);
  });

  test('疑似离线且无本地副本/缓存：抛 SuspectedOfflineException 且不取流', () async {
    final harness = Harness(suspectedOffline: true);

    await expectLater(
      harness.resolver().resolve(episodeId: 'e1', playNetworkUrl: harness.play),
      throwsA(isA<SuspectedOfflineException>()),
    );
    expect(harness.streamCalls, 0);
    expect(harness.fullCalls, 0);
    expect(harness.played, isEmpty);
    expect(harness.successCalls, 0);
  });

  test('即使疑似离线，预取地址命中仍优先起播（本地已拿到地址）', () async {
    const prefetched = 'http://127.0.0.1:18931/src/prefetched.mp4';
    final harness = Harness(prefetchedUrl: prefetched, suspectedOffline: true);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.prefetched);
    expect(harness.played, <String>[prefetched]);
  });

  test('stream 成功：记一次网络成功，不起播整集下载', () async {
    final harness = Harness();

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.stream);
    expect(resolved.url, harness.streamUrl);
    expect(harness.played, <String>[harness.streamUrl]);
    expect(harness.successCalls, 1);
    expect(harness.fullCalls, 0);
  });

  test('stream 取流失败：回退整集下载并记网络成功', () async {
    final harness = Harness(streamThrows: true);

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.fullDownload);
    expect(harness.played, <String>[harness.fullUrl]);
    expect(harness.successCalls, 1);
    expect(harness.refreshFlags, <bool>[
      false,
      false,
    ], reason: 'stream 与整集回退都不带 refresh');
  });

  test('stream 起播失败（controller initialize 抛错）：回退整集下载', () async {
    final harness = Harness(
      playThrows: (attempt) =>
          attempt == 0 ? StateError('AVPlayer init failed') : null,
    );

    final resolved = await harness.resolver().resolve(
      episodeId: 'e1',
      playNetworkUrl: harness.play,
    );

    expect(resolved!.origin, EpisodeSourceOrigin.fullDownload);
    expect(harness.played, <String>[harness.streamUrl, harness.fullUrl]);
    expect(harness.fullCalls, 1);
  });

  test('只解析地址（playNetworkUrl=null）：返回地址但不起播（预热/预取用）', () async {
    final harness = Harness(
      prefetchedUrl: 'http://127.0.0.1:18931/src/pre.mp4',
    );

    final resolved = await harness.resolver().resolve(episodeId: 'e1');

    expect(resolved!.origin, EpisodeSourceOrigin.prefetched);
    expect(resolved.url, 'http://127.0.0.1:18931/src/pre.mp4');
    expect(harness.played, isEmpty);
  });

  test('取消（isCancelled=true）：返回 null 且不继续取流', () async {
    final harness = Harness();

    final resolved = await harness
        .resolver(isCancelled: () => true)
        .resolve(episodeId: 'e1', playNetworkUrl: harness.play);

    expect(resolved, isNull);
    expect(harness.cachedCalls, 0);
    expect(harness.streamCalls, 0);
    expect(harness.played, isEmpty);
  });

  test('取消发生在起播失败后：返回 null，不把失败当普通错误继续回退', () async {
    var cancelled = false;
    final harness = Harness(
      prefetchedUrl: 'http://127.0.0.1:18931/src/pre.mp4',
    );

    final resolved = await harness
        .resolver(isCancelled: () => cancelled)
        .resolve(
          episodeId: 'e1',
          playNetworkUrl: (url) async {
            cancelled = true;
            throw StateError('切换到别的集了');
          },
        );

    expect(resolved, isNull);
    expect(harness.cachedCalls, 0, reason: '已取消就不再探测下一级');
    expect(harness.streamCalls, 0);
  });
}
