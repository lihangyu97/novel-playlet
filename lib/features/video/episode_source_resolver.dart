import 'dart:io';

import '../../data/models/video_source.dart';
import 'offline_playback.dart';
import 'playback_failure.dart';

/// 这一集最终用哪种源播放（失败详情/诊断区分用）。
enum EpisodeSourceOrigin {
  /// 离线 pinned 区的本地明文 mp4。
  offlineFile,

  /// 播放页 5s 预取拿到的 `/src` 地址。
  prefetched,

  /// 内核 `mode=cached` 命中的完整缓存地址。
  kernelCache,

  /// 内核 `mode=stream` 的边下边播地址。
  stream,

  /// 回退的整集下载地址。
  fullDownload,
}

/// 一次取源的结果。
///
/// 本地文件由调用方建 `VideoPlayerController.file`；网络源在传入
/// [EpisodeSourceResolver.resolve] 的 `playNetworkUrl` 回调里已经交接过
/// （resolver 只是把候选地址按级联顺序递给播放器）。
class ResolvedEpisodeSource {
  const ResolvedEpisodeSource._({this.file, this.url, required this.origin});

  factory ResolvedEpisodeSource.localFile(File file) => ResolvedEpisodeSource._(
    file: file,
    origin: EpisodeSourceOrigin.offlineFile,
  );

  factory ResolvedEpisodeSource.network(
    String url,
    EpisodeSourceOrigin origin,
  ) => ResolvedEpisodeSource._(url: url, origin: origin);

  final File? file;
  final String? url;
  final EpisodeSourceOrigin origin;

  bool get isLocal => file != null;

  /// 失败详情里展示的地址（本地为路径，网络为 URL）。
  String get location => file?.path ?? url ?? '';
}

/// 「疑似离线、这一集又没有本地副本」。
///
/// 单独一个类型是为了让页面的 catch 能区分「真的取流失败」和「按策略主动
/// 跳过」：后者不再记一次网络失败，但同样落到「未离线缓存」的文案。
class SuspectedOfflineException implements Exception {
  const SuspectedOfflineException();

  @override
  String toString() => 'network recently failed; skipped source resolution';
}

/// 一集的离线副本加载器（`refresh: true` 表示用户要求重下：可能删掉坏副本）。
typedef EpisodeOfflineFileLoader = Future<File?> Function(
  String episodeId, {
  required bool refresh,
});

/// 内核本地缓存探测（`mode=cached`）：命中返回回环地址，未命中 null。
typedef EpisodeCachedUrlProbe = Future<String?> Function(String episodeId);

/// 内核取流：`stream: true` 对应 `mode=stream`，否则整集下载；[refresh] 只对
/// 整集下载有意义（删缓存重下）。
typedef EpisodeSourceFetcher = Future<VideoSource> Function(
  String episodeId, {
  required bool stream,
  required bool refresh,
});

/// 取走页内预取的 `/src` 地址（取走后即失效）。
typedef EpisodePrefetchedUrlTaker = String? Function(String episodeId);

/// 把候选地址交给播放器（建 controller + initialize + 起播）。
///
/// resolver 不关心实现：播放失败时它按级联继续回退，除非失败是回环
/// connect refused（换地址也播不了，交给页面做一次有界自愈）。
typedef EpisodeNetworkPlay = Future<void> Function(String url);

/// 一集的取流级联：**离线 → 预取 → 内核缓存 → stream → 整集下载**。
///
/// 原来这套顺序在播放页里有三份实现（正式起播 / 翻页预热 / 下一集预取），
/// 细节已漂移；这里收成一份，差异用参数表达：
///
/// - `refresh: true`（用户点「重新下载这一集」）：跳过预取/内核缓存/stream，
///   直接整集重取；
/// - `playNetworkUrl == null`：只解析地址不起播（翻页预热、预取用）；
/// - [isCancelled]：每次 await 后判定，返回 `null` 表示本次取源被更新的请求
///   取代，调用方直接返回；
/// - 成功取流用 [recordSuccess] 清「疑似离线」；失败不在这里记录——页面
///   需要先做 -1004 有界自愈，再决定是否 [recordFailure]，顺序不能变。
///
/// 所有 IO 都是注入回调，resolver 本身不碰 `ref` / provider / `State`，
/// 因此每条回落分支都能在纯 Dart 测试里覆盖。
class EpisodeSourceResolver {
  const EpisodeSourceResolver({
    required this.loadOfflineFile,
    required this.takePrefetchedUrl,
    required this.probeCachedUrl,
    required this.fetchSource,
    required this.isSuspectedOffline,
    required this.recordSuccess,
    this.isCancelled,
  });

  final EpisodeOfflineFileLoader loadOfflineFile;
  final EpisodePrefetchedUrlTaker takePrefetchedUrl;
  final EpisodeCachedUrlProbe probeCachedUrl;
  final EpisodeSourceFetcher fetchSource;
  final bool Function() isSuspectedOffline;
  final void Function() recordSuccess;
  final bool Function()? isCancelled;

  /// 解析 [episodeId] 这一集该用哪个源。
  ///
  /// 返回 `null` = 本次取源已被取消（调用方直接 return，不要当失败处理）。
  Future<ResolvedEpisodeSource?> resolve({
    required String episodeId,
    bool refresh = false,
    EpisodeNetworkPlay? playNetworkUrl,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    // 1) 离线副本优先：命中就直接开本地明文 mp4，不请求内核、不等待「准备播放」。
    final offline = await loadOfflineFile(episodeId, refresh: refresh);
    if (cancelled()) return null;
    final plan = resolveOfflineEpisode(cachedFile: offline, offline: false);
    if (plan.isLocal) return ResolvedEpisodeSource.localFile(plan.file!);

    Future<ResolvedEpisodeSource> handOff(
      String url,
      EpisodeSourceOrigin origin,
    ) async {
      await playNetworkUrl?.call(url);
      return ResolvedEpisodeSource.network(url, origin);
    }

    // 预取地址无论是否走捷径都先取走：refresh 表示用户要求重新取流，旧的
    // `/src` 已不可信，不能留在页内 LRU 里被下一次切集误用。
    final prefetched = takePrefetchedUrl(episodeId);

    if (!refresh) {
      // 2) 当前集播放期间预取的下一集：命中就省掉一次取流（缓存未命中时
      // 那次会整集下载，是切集等待的大头）。预取的 `/src` 可能已被内核
      // 128MB 预算淘汰，起播失败就回退正常取流；但「回环监听被回收」不是
      // 地址问题，回退只会再失败一次，抛给页面自愈。
      if (prefetched != null) {
        try {
          return await handOff(prefetched, EpisodeSourceOrigin.prefetched);
        } catch (error) {
          if (isLoopbackConnectRefused(error)) rethrow;
          if (cancelled()) return null;
        }
      }

      // 3) 先探内核本地缓存（mode=cached）：命中就不打上游，断网也能播自动
      // 缓存集。
      final cachedUrl = await _probeCachedUrlQuietly(episodeId);
      if (cancelled()) return null;
      if (cachedUrl != null) {
        try {
          return await handOff(cachedUrl, EpisodeSourceOrigin.kernelCache);
        } catch (error) {
          // 缓存条目可能刚被淘汰/半截：继续走正常取流。
          if (isLoopbackConnectRefused(error)) rethrow;
          if (cancelled()) return null;
        }
      }

      // 4) 刚发生过网络类失败：这一集又没有离线副本 / 本地缓存，别再付一次
      // 完整取流等待（黑洞网络下内核重试会耗几十秒），交给页面给可操作文案。
      if (isSuspectedOffline()) throw const SuspectedOfflineException();
    }

    // 5) 在线优先走 mode=stream：内核立即返回 `/src` 地址并在后台继续下载，
    // 起播不用等整集落盘。refresh（用户要求重新下载这一集）跳过它。
    if (!refresh) {
      try {
        final streamed = await fetchSource(
          episodeId,
          stream: true,
          refresh: false,
        );
        if (cancelled()) return null;
        recordSuccess();
        return await handOff(streamed.url, EpisodeSourceOrigin.stream);
      } catch (error) {
        if (cancelled()) return null;
        // stream 取流/起播失败：回退整集下载兜底，不能因为新模式把原本能播
        // 的集变成错误页；-1004 回退也播不了，交给页面自愈。
        if (isLoopbackConnectRefused(error)) rethrow;
      }
    }

    // 6) 默认整集下载（refresh 时同样走这里：跳过所有本地/流式捷径）。
    final source = await fetchSource(
      episodeId,
      stream: false,
      refresh: refresh,
    );
    if (cancelled()) return null;
    recordSuccess();
    return handOff(source.url, EpisodeSourceOrigin.fullDownload);
  }

  Future<String?> _probeCachedUrlQuietly(String episodeId) async {
    try {
      return await probeCachedUrl(episodeId);
    } catch (_) {
      // 探测失败当 miss，错误交给正常取流路径展示。
      return null;
    }
  }
}
