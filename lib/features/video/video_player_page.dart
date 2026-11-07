import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/video_source.dart';
import '../cache/cache_providers.dart';
import 'offline_playback.dart';
import 'playback_speed.dart';
import 'widgets/episode_picker_sheet.dart';
import 'widgets/playback_speed_sheet.dart';
import 'widgets/player_option_chip.dart';

/// controller 工厂：生产环境走 `video_player` 的 platformView，测试可 override
/// 成 FakeController（不碰平台通道），用于锁「切集保留旧画面/倍速继承」等行为。
typedef PlaybackControllerFactory = VideoPlayerController Function({
  File? file,
  Uri? networkUrl,
});

final playbackControllerFactoryProvider = Provider<PlaybackControllerFactory>((
  ref,
) {
  return ({File? file, Uri? networkUrl}) {
    assert((file != null) != (networkUrl != null), 'file / networkUrl 必须二选一');
    if (file != null) {
      // 无弹幕叠加需求，平台视图底层就是 AVPlayerLayer：少一次逐帧纹理
      // 拷贝，发热和功耗更好。若真机上发现浮层被原生视图遮挡，可退回默认
      // 的 textureView（见 docs/video-playback.md 4.1）。
      return VideoPlayerController.file(
        file,
        viewType: VideoViewType.platformView,
      );
    }
    return VideoPlayerController.networkUrl(
      networkUrl!,
      viewType: VideoViewType.platformView,
    );
  };
});

/// 播放页：AVPlayer（`video_player`）播放内核解密后的本地 HTTP 流。
///
/// 一集一个 controller：切集就换 controller（换档/换集都走同一条路），
/// 播放中的 controller 不跨集复用——AVPlayer 对同一 item 换源不如重建稳。
///
/// 后台/画中画/HDR 本轮不做（见 docs/video-playback.md）：退后台不做显式
/// 暂停，回前台仍在播放就继续。
///
/// 方向：App 全局竖屏（`main.dart` 锁定），只有横屏视频（宽高比 > 1.05）才在
/// 播放页给出「全屏」按钮，点了才临时放开横屏；退出全屏或离开播放页立刻恢复
/// 竖屏，避免横屏状态漏到其它页面。
class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({super.key, required this.args});

  final VideoPlayArgs args;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  late int _index;

  VideoPlayerController? _controller;
  bool _loading = true;

  /// 播放失败的原因 + 可复制的技术详情。播放页的失败原因不止"网络"，也可能是
  /// 缓存文件半截、编码不支持、ATS 拦截，所以不能只给一句"请重试"。
  _PlaybackFailure? _error;

  /// 异步换集的结果校验：用户连续点下一集时，旧请求回来必须丢弃。
  int _generation = 0;

  /// 播完自动下一集只触发一次（完成事件会重复到达）。
  bool _advancing = false;

  /// 控制条显隐：播放中 3.5s 后自动隐藏，点画面切换。暂停时强制常显。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 拖动进度条时的临时位置。松手才 seek，避免每个 tick 都打一次 Range。
  double? _dragValue;

  /// 是否处于横屏全屏。只有横屏内容才给入口：竖屏视频全屏只会更小。
  bool _fullscreen = false;

  /// 上一集的 controller：切集先保留它的最后一帧，等新集真正出画面后再释放。
  ///
  /// 切集立刻 dispose 旧 controller 会让画面瞬间变黑，哪怕新集只用几百毫秒
  /// 就绪，观感也是「卡了一下」；保留旧画面可以把这个空窗盖住。
  VideoPlayerController? _retained;

  /// 有旧画面兜底时延迟显示 spinner：本地文件通常在新画面出来前就绪，
  /// 不应该闪一下「正在准备视频…」。
  Timer? _spinnerTimer;
  bool _showSpinner = false;

  /// iOS 16+ 的 AVPlayer 会在「真正起播 / seek」后把 rate 复位成 defaultRate
  /// （1.0）；video_player 在 play() 里补的那次 setPlaybackSpeed 可能抢在起播
  /// 之前，所以 UI 显示 2x、实际还在 1x。这里在首帧/seek 后补设一次。
  bool _wasPlaying = false;
  bool _speedReapplyPending = false;
  final List<Timer> _speedReapplyTimers = <Timer>[];

  /// 预取下一集的取流结果（episodeId → source）。缓存未命中时内核会整集
  /// 下载，把这段耗时移到当前集播放期间，切集只用拿现成的 `/src` 地址。
  final Map<String, VideoSource> _prefetched = {};
  final Set<String> _prefetching = {};
  Timer? _prefetchTimer;

  /// 横屏判定：接近 1 的方图不算，避免给错按钮。
  static const double _landscapeAspect = 1.05;

  List<Chapter> get _episodes => widget.args.episodes;

  Chapter? get _episode =>
      _index >= 0 && _index < _episodes.length ? _episodes[_index] : null;

  @override
  void initState() {
    super.initState();
    final lastIndex = _episodes.isEmpty ? 0 : _episodes.length - 1;
    _index = widget.args.index < 0
        ? 0
        : (widget.args.index > lastIndex ? lastIndex : widget.args.index);
    unawaited(_open(_index));
  }

  @override
  void dispose() {
    _generation += 1;
    _hideTimer?.cancel();
    _spinnerTimer?.cancel();
    _prefetchTimer?.cancel();
    _cancelSpeedReapplyTimers();
    _disposeController();
    _disposeRetained();
    // 带着全屏状态退出播放页时，下一次进别的页面还在横屏就糟了。
    if (_fullscreen) unawaited(_restorePortrait());
    super.dispose();
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(controller.dispose());
    }
  }

  /// 把当前 controller 降级成「上一帧」：暂停并留着画面，不立刻 dispose。
  ///
  /// 只保留一个（新的切集会先释放更早的保留项），避免连续切集时 AVPlayer
  /// 数量越积越多。
  void _retainCurrentController() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    if (!controller.value.isInitialized) {
      unawaited(controller.dispose());
      return;
    }
    // 保留的是静音画面：不能让它继续出声。
    unawaited(controller.pause());
    _disposeRetained();
    _retained = controller;
  }

  void _disposeRetained() {
    final retained = _retained;
    _retained = null;
    if (retained != null) unawaited(retained.dispose());
  }

  Future<void> _open(
    int index, {
    bool refresh = false,
    bool autoAdvance = false,
  }) async {
    if (_episodes.isEmpty) return;
    final episode = _episodes[index];
    final generation = ++_generation;
    _advancing = false;
    _hideTimer?.cancel();
    _prefetchTimer?.cancel();
    _cancelSpeedReapplyTimers();
    _wasPlaying = false;
    _speedReapplyPending = false;
    // 旧画面先留着垫底，等新集真正出画面再释放（见
    // docs/playback-quality-speed.md §1.4 P0-2）。
    _retainCurrentController();
    String sourceUrl = '';
    String localPath = '';
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      // 控制条只在首次进入播放页、或用户点屏幕后出现；播完自动切下一集
      // 是「被动续播」，不应该再把控制条弹出来打断观看（见
      // docs/playback-quality-speed.md §4.4）。
      _controlsVisible = !autoAdvance;
      _dragValue = null;
      // 有上一帧兜底时先不闪 spinner：本地文件往往 200ms 内就绪。
      _showSpinner = _retained == null;
    });
    _spinnerTimer?.cancel();
    if (!_showSpinner) {
      _spinnerTimer = Timer(const Duration(milliseconds: 250), () {
        if (!mounted || !_loading) return;
        setState(() => _showSpinner = true);
      });
    }

    try {
      // 离线副本优先：命中就直接开本地明文 mp4，不请求内核、不等待
      // 「准备播放」。未命中才走原来的在线流程（见 docs/offline-cache.md §6.2）。
      final offlineFile = await _offlineFile(episode.id, refresh: refresh);
      if (!mounted || generation != _generation) return;
      // 「确认离线」只能在取流失败后推断，所以这里先按在线尝试。
      final plan = resolveOfflineEpisode(
        cachedFile: offlineFile,
        offline: false,
      );
      if (plan.isLocal) {
        localPath = plan.file!.path;
        final controller = ref.read(playbackControllerFactoryProvider)(
          file: plan.file!,
        );
        await _startController(
          controller,
          index: index,
          generation: generation,
          autoAdvance: autoAdvance,
        );
        return;
      }

      final api = ref.read(apiClientProvider);
      final factory = ref.read(playbackControllerFactoryProvider);

      Future<void> playUrl(String url) async {
        sourceUrl = url;
        await _startController(
          factory(networkUrl: Uri.parse(url)),
          index: index,
          generation: generation,
          autoAdvance: autoAdvance,
        );
      }

      // 当前集播放期间预取的下一集：命中就省掉一次取流（缓存未命中时那次
      // 会整集下载，是切集等待的大头）。
      final cachedSource = _prefetched.remove(episode.id);
      final prefetched = refresh ? null : cachedSource;
      if (prefetched != null) {
        try {
          await playUrl(prefetched.url);
          return;
        } catch (_) {
          // 预取的 `/src` 可能已被内核 128MB 预算淘汰：回退正常取流。
        }
      }

      // 先探内核本地缓存（mode=cached）：命中就不打上游，断网也能播自动缓存集。
      if (!refresh) {
        String? cachedUrl;
        try {
          cachedUrl = await api.cachedVideoUrl(episode.id);
        } catch (_) {
          // 探测失败当 miss，错误交给正常取流路径展示。
        }
        if (!mounted || generation != _generation) return;
        if (cachedUrl != null) {
          try {
            await playUrl(cachedUrl);
            return;
          } catch (_) {
            // 缓存条目可能刚被淘汰/半截：继续走正常取流。
          }
        }
      }

      final source = await api.videoSource(episode.id, refresh: refresh);
      if (!mounted || generation != _generation) return;
      await playUrl(source.url);
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      _spinnerTimer?.cancel();
      _disposeRetained();
      // 没有离线副本、失败又像「网络不可达」：换成明确文案；网络在线时保留
      // 原来的失败原因（上游/鉴权/解码各有各的说明 + 重试入口）。
      final missedOffline = resolveOfflineEpisode(
        cachedFile: null,
        offline: isOfflineNetworkFailure(error),
      );
      setState(() {
        _loading = false;
        _showSpinner = false;
        _error = missedOffline.source == EpisodePlaybackSource.offlineMiss
            ? _PlaybackFailure(
                title: EpisodePlaybackPlan.offlineMissTitle,
                reason: EpisodePlaybackPlan.offlineMissReason,
                detail: _playbackDetail(
                  episode,
                  sourceUrl: sourceUrl,
                  localPath: localPath,
                  refreshed: refresh,
                  error: error,
                  stack: stack,
                ),
              )
            : _describePlaybackError(
                error,
                stack: stack,
                episode: episode,
                sourceUrl: sourceUrl,
                localPath: localPath,
                refreshed: refresh,
              );
      });
    }
  }

  /// 初始化并接管 controller（离线本地文件 / 在线流共用）。
  ///
  /// 初始化成功后立刻上屏并开播；换集竞态（generation 对不上）时丢弃旧
  /// controller，避免两集抢同一个画面。
  Future<void> _startController(
    VideoPlayerController controller, {
    required int index,
    required int generation,
    bool autoAdvance = false,
  }) async {
    try {
      await controller.initialize();
    } catch (_) {
      unawaited(controller.dispose());
      rethrow;
    }
    if (!mounted || generation != _generation) {
      unawaited(controller.dispose());
      return;
    }
    // 新 controller 默认是 1.0x，切集/换源必须把全局倍速重新 apply 一次。
    // 暂停态调用只记值不下发，真正下发由随后的 play() 完成（插件语义）。
    await controller.setPlaybackSpeed(ref.read(playbackSpeedProvider));
    await controller.setLooping(false);
    _controller = controller;
    _spinnerTimer?.cancel();
    setState(() {
      _loading = false;
      _showSpinner = false;
    });
    // 换集后方向可能变：全屏中切到竖屏视频要退回竖屏，否则画面缩成一条。
    if (_fullscreen && !_isLandscapeVideo(controller.value)) {
      unawaited(_exitFullscreen());
    }
    controller.addListener(_onTick);
    await controller.play();
    // 自动续播不弹控制条，自然也不需要自动隐藏计时（它本来就是隐藏的）。
    if (!autoAdvance) _scheduleHide();
    // 当前集播起来后再预取下一集：此时整集下载不占关键路径，也不至于
    // 用户秒退还白下一条。
    _schedulePrefetch();
    // 真正播起来才记历史：取流失败/初始化失败的那一集不应该进最近观看。
    // 离线播放也算看过，进度照存。
    final args = widget.args;
    if (args.seriesId.isNotEmpty) {
      unawaited(
        ref
            .read(readingStoreProvider)
            .saveVideoProgress(
              seriesId: args.seriesId,
              title: args.seriesTitle,
              cover: args.cover,
              episodeIndex: index,
            ),
      );
    }
  }

  /// 查这一集有没有离线副本。
  ///
  /// `refresh: true`（用户点「重新下载这一集」）时认为本地副本可能已损坏：
  /// 先删掉它再走网络，让这次重试真正重新取流；否则坏文件会让每次点重试
  /// 都回到同一个打不开的本地文件。删除失败不影响在线播放。
  Future<File?> _offlineFile(String episodeId, {required bool refresh}) async {
    final seriesId = widget.args.seriesId;
    if (seriesId.isEmpty || episodeId.isEmpty) return null;
    final store = ref.read(offlineSeriesStoreProvider);
    try {
      final cached = await store.episodeFileIfCached(seriesId, episodeId);
      if (cached == null || !refresh) return cached;
      // 用户点「重新下载这一集」：本地副本可能已损坏，删掉后走网络重新取流。
      // 顺带按文件存在校正 manifest，否则详情页/缓存中心会继续显示这一集「已缓存」。
      await cached.delete();
      await store.reconcile(seriesId);
    } catch (_) {
      // 离线区读/删/校正失败（权限、插件缺失等）不能拖垮在线播放。
    }
    if (refresh) {
      ref.invalidate(offlineVideoStatsProvider);
      ref.invalidate(offlineVideoListProvider);
      ref.invalidate(offlineSeriesProvider(seriesId));
    }
    return null;
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    // 起播 / 缓冲恢复时重新补一次倍速（见 _speedReapplyPending 注释）。
    if (value.isPlaying != _wasPlaying) {
      _wasPlaying = value.isPlaying;
      if (value.isPlaying) _scheduleSpeedReapply(_generation);
    }
    if (_speedReapplyPending &&
        value.isPlaying &&
        value.position > Duration.zero) {
      _speedReapplyPending = false;
      _applyPlaybackSpeedNow();
    }
    // 新集真正出画面（position 前进）后，把垫底的上一帧释放掉：太早释放会
    // 在平台视图创建前露一下黑屏，太晚则一直多占一个 AVPlayer。
    if (_retained != null &&
        value.isPlaying &&
        value.position > Duration.zero) {
      _disposeRetained();
      setState(() {});
    }
    if (_advancing) return;
    // AVPlayer 没有可靠的 completed 流，用「播到尾部且不再前进」判定；
    // 留 250ms 容差，避免最后一帧的抖动误触发。
    if (value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 250) &&
        !value.isPlaying) {
      _advancing = true;
      if (_index + 1 < _episodes.length) {
        // 播完自动续播：不要像首次进入那样弹出控制条。
        unawaited(_open(_index + 1, autoAdvance: true));
      }
    }
  }

  /// 当前集播了几秒后再预取下一集：避免用户秒退也白下一整集。
  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      unawaited(_prefetchNext());
    });
  }

  /// 预取下一集的取流结果。
  ///
  /// 缓存未命中时这次调用会把整集下载进内核缓存（产品已确认允许），切集时
  /// 直接拿现成的 `/src` 地址，把下载移出关键路径。失败静默——切集时还有
  /// 正常取流兜底，不需要打扰用户。
  Future<void> _prefetchNext() async {
    final next = _index + 1;
    if (next >= _episodes.length) return;
    final episode = _episodes[next];
    if (episode.id.isEmpty) return;
    if (_prefetched.containsKey(episode.id) ||
        _prefetching.contains(episode.id)) {
      return;
    }
    // 离线命中不需要预取：本地文件本身就是秒开。
    final seriesId = widget.args.seriesId;
    if (seriesId.isNotEmpty) {
      try {
        final file = await ref
            .read(offlineSeriesStoreProvider)
            .episodeFileIfCached(seriesId, episode.id);
        if (file != null) return;
      } catch (_) {
        // 离线区读失败不影响在线预取。
      }
    }
    if (!mounted || _prefetching.contains(episode.id)) return;
    _prefetching.add(episode.id);
    try {
      final api = ref.read(apiClientProvider);
      // 先探本地缓存：命中就不用为预取再触发整集下载。
      String? cachedUrl;
      try {
        cachedUrl = await api.cachedVideoUrl(episode.id);
      } catch (_) {
        // 探测失败当 miss。
      }
      if (!mounted) return;
      final source = cachedUrl != null
          ? VideoSource(url: cachedUrl)
          : await api.videoSource(episode.id);
      if (!mounted) return;
      // 页内只留最近两条：追剧时无限积累没有意义。
      while (_prefetched.length >= 2) {
        _prefetched.remove(_prefetched.keys.first);
      }
      _prefetched[episode.id] = source;
    } catch (_) {
      // 预取失败静默：切集时走正常取流，失败原因由播放页统一展示。
    } finally {
      _prefetching.remove(episode.id);
    }
  }

  /// 把播放异常翻译成"人话原因 + 可复制的技术详情"。
  ///
  /// 失败发生在两段：`videoSource`（内核取流/整集下载，抛 ApiException；
  /// B2 之后 504 超时已被 ApiClient 归一成 `ApiException(kind: timeout)`，
  /// 只有 499 取消还走 TimeoutException）和 `controller.initialize()`
  /// （AVPlayer，抛 PlatformException，msg 里带 AVFoundation 的 `Code=-xxxxx`）。
  _PlaybackFailure _describePlaybackError(
    Object error, {
    required StackTrace stack,
    required Chapter episode,
    required String sourceUrl,
    required String localPath,
    required bool refreshed,
  }) {
    final raw = error.toString();
    final rawLower = raw.toLowerCase();
    String title;
    String reason;

    // 504 超时（ApiException.kind == timeout）与 499 取消的 TimeoutException
    // 都按"取流超时"展示：B2 之后超时不再落进通用"取流失败"。
    final timedOut =
        error is TimeoutException ||
        (error is ApiException && error.kind == ApiErrorKind.timeout);
    if (timedOut) {
      title = '取流超时';
      reason = '等内核下载/解密这一集超过 120 秒。常见于网络慢、上游限速，或这一集体积过大。';
    } else if (error is ApiException) {
      title = '取流失败';
      // 具体原因优先；技术兜底换 kind 短句（deviceFailed 会提示重启应用）。
      reason = apiErrorCopy(error, fallback: '取流失败，请重试');
    } else if (error is PlatformException) {
      final text = [
        error.code,
        error.message ?? '',
        error.details?.toString() ?? '',
      ].join(' | ');
      if (RegExp(r'-1022|App Transport Security').hasMatch(text)) {
        title = '本地视频流被 ATS 拦截';
        reason = 'iOS 拒绝了 http://127.0.0.1 的回环请求（Info.plist 的 ATS 例外没生效）。';
      } else if (RegExp(r'-1001|-1005|-1009|-1011|-1012|-1200|-1202')
          .hasMatch(text)) {
        title = '本地视频流连接中断';
        reason =
            'AVPlayer 读本地回环流时断开了：常见于内核下载被中断（App 切后台）、'
            '或回环服务被系统回收。点「重新下载这一集」重试。';
      } else if (RegExp(
        r'-1102|-11800|-11828|-11829|avfoundationerrordomain|decode|format',
        caseSensitive: false,
      ).hasMatch(text)) {
        title = '视频解码失败';
        reason = localPath.isNotEmpty
            ? '离线缓存文件可能损坏（下载不完整或被外部清理）。'
                  '点「重新下载这一集」会删掉本地文件后重新联网取流。'
            : '这一集的文件可能损坏（半截缓存）或编码不受支持。'
                  '可以点「重新下载这一集」清掉缓存重取。';
      } else if (RegExp(r'403|404|410').hasMatch(text)) {
        title = '本地视频地址失效';
        reason = '回环服务对 /src 返回了 4xx，多半是缓存被清理或内核重启过。重新下载这一集即可。';
      } else {
        title = 'AVPlayer 播放失败';
        reason = '播放器内部错误，具体信息见下方。';
      }
      // 兜底：有些插件版本把网络类错误包在 message 的英文描述里。
      if (title == 'AVPlayer 播放失败' && rawLower.contains('network')) {
        title = '本地视频流连接中断';
        reason = '播放器报告网络类错误，详情见下方。';
      }
    } else {
      title = '视频播放失败';
      reason = '未归类的错误，详情见下方。';
    }

    return _PlaybackFailure(
      title: title,
      reason: reason,
      detail: _playbackDetail(
        episode,
        sourceUrl: sourceUrl,
        localPath: localPath,
        refreshed: refreshed,
        error: error,
        stack: stack,
      ),
    );
  }

  /// 可复制的技术详情：集 id、地址、原始异常、堆栈前几行。
  String _playbackDetail(
    Chapter episode, {
    required String sourceUrl,
    required String localPath,
    required bool refreshed,
    required Object error,
    required StackTrace stack,
  }) {
    final frames = stack.toString().split('\n').take(4).join('\n');
    return [
      '《${widget.args.seriesTitle}》第 ${_index + 1} 集 ${episode.title}（id=${episode.id}）',
      if (sourceUrl.isNotEmpty) '播放地址: $sourceUrl',
      if (localPath.isNotEmpty) '离线文件: $localPath',
      if (refreshed) '本次为「重新下载这一集」后的结果',
      '错误类型: ${error.runtimeType}',
      '原始错误: $error',
      if (frames.isNotEmpty) '堆栈(前 4 行):\n$frames',
    ].join('\n');
  }

  Future<void> _copyError() async {
    final error = _error;
    if (error == null) return;
    await Clipboard.setData(
      ClipboardData(text: '${error.title}\n${error.reason}\n${error.detail}'),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('错误信息已复制')));
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
      // 暂停时把控制条钉住，否则刚点完就消失，用户看不到自己暂停了。
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
    } else {
      if (_advancing) {
        _advancing = false;
      }
      unawaited(controller.play());
      _scheduleSpeedReapply(_generation);
      _scheduleHide();
    }
  }

  /// 3.5s 后自动隐藏控制条；只在真的在播放时隐藏。
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      final controller = _controller;
      if (controller == null || !controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  bool _isLandscapeVideo(VideoPlayerValue value) =>
      value.isInitialized && value.aspectRatio > _landscapeAspect;

  /// 全屏入口只在横屏视频上出现；尺寸信息来自 AVPlayer 的 presentationSize。
  bool get _canFullscreen {
    final controller = _controller;
    if (controller == null) return false;
    return _isLandscapeVideo(controller.value);
  }

  Future<void> _toggleFullscreen() async {
    if (_fullscreen) {
      await _exitFullscreen();
    } else {
      await _enterFullscreen();
    }
  }

  Future<void> _enterFullscreen() async {
    if (!_canFullscreen) return;
    setState(() => _fullscreen = true);
    _hideTimer?.cancel();
    // 只在横屏视频、且用户主动点按钮时放开横屏；App 其余时间都是竖屏。
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // iOS 只认 manual + overlays 的方式隐藏状态栏（leanBack/immersive 是
    // Android 语义，在 iOS 上不会生效）。
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: const <SystemUiOverlay>[],
    );
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _exitFullscreen() async {
    if (!mounted) return;
    setState(() => _fullscreen = false);
    await _restorePortrait();
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  /// 恢复全局竖屏 + 正常状态栏。dispose 里也走这里。
  Future<void> _restorePortrait() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  void _seekTo(Duration position) {
    final controller = _controller;
    if (controller == null) return;
    _advancing = false;
    unawaited(_seekAndKeepSpeed(controller, position));
  }

  /// seek 后补倍速：iOS 16+ 的 AVPlayer 会在 seek 完成后把 rate 复位到
  /// defaultRate(1.0)，不补的话 UI 还是 2x、实际已经回到 1x。
  Future<void> _seekAndKeepSpeed(
    VideoPlayerController controller,
    Duration position,
  ) async {
    await controller.seekTo(position);
    if (!mounted || _controller != controller) return;
    _scheduleSpeedReapply(_generation);
    _applyPlaybackSpeedNow();
  }

  /// 把当前倍速重新下发给 controller（幂等；暂停时 Dart 层只存值不下发）。
  void _applyPlaybackSpeedNow() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    unawaited(controller.setPlaybackSpeed(ref.read(playbackSpeedProvider)));
  }

  /// 在起播/seek 之后补几次倍速：首帧 tick 一次 + 400ms/1200ms 两个兜底，
  /// 覆盖 AVFoundation 起播、seek、缓冲恢复等会重置 rate 的时点。
  void _scheduleSpeedReapply(int generation) {
    _cancelSpeedReapplyTimers();
    _speedReapplyPending = true;
    for (final delay in const [
      Duration(milliseconds: 400),
      Duration(milliseconds: 1200),
    ]) {
      _speedReapplyTimers.add(
        Timer(delay, () {
          if (!mounted || generation != _generation) return;
          _applyPlaybackSpeedNow();
        }),
      );
    }
  }

  void _cancelSpeedReapplyTimers() {
    for (final timer in _speedReapplyTimers) {
      timer.cancel();
    }
    _speedReapplyTimers.clear();
    _speedReapplyPending = false;
  }

  Future<void> _openEpisodePicker() async {
    final picked = await showEpisodePickerSheet(
      context,
      episodes: _episodes,
      currentIndex: _index,
      seriesTitle: widget.args.seriesTitle,
    );
    if (!mounted || picked == null || picked == _index) return;
    await _open(picked);
  }

  void _openPrevious() {
    if (_index <= 0) return;
    unawaited(_open(_index - 1));
  }

  void _openNext() {
    if (_index + 1 >= _episodes.length) return;
    unawaited(_open(_index + 1));
  }

  /// 打开倍速弹层：只写 provider，由 build 里的 listener 统一下发给 controller。
  Future<void> _openPlaybackSpeedSheet() async {
    _hideTimer?.cancel();
    final picked = await showPlaybackSpeedSheet(
      context,
      current: ref.read(playbackSpeedProvider),
    );
    if (!mounted) return;
    if (picked != null) {
      ref.read(playbackSpeedProvider.notifier).setSpeed(picked);
    }
    // 弹层关掉后恢复自动隐藏；暂停态由 _scheduleHide 自己判断不隐藏。
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final episodeTitle = _episode?.title.isNotEmpty == true
        ? _episode!.title
        : '第 ${_index + 1} 集';
    // 加载期间也保留顶栏（返回键/剧名），不要整屏只剩 spinner。
    final showChrome = _error == null;
    final speed = ref.watch(playbackSpeedProvider);
    ref.listen<double>(playbackSpeedProvider, (_, next) {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      // 暂停时也要调：Dart 层只存值不下发，恢复播放时会按旧值 apply。
      unawaited(controller.setPlaybackSpeed(next));
    });
    return PopScope(
      // 全屏时系统返回手势/返回键先退全屏，再返回才是离开播放页。
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_exitFullscreen());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 视频铺满整屏：全屏横屏时也要盖住底部安全区（Home 指示条那一条），
            // 否则画面下方会留一道黑边。顶部控制条始终避让状态栏；底部控制条
            // 只在竖屏避让安全区——全屏横屏时贴到屏幕最底边，否则 Home 指示条
            // 那一条会在控件下面留出空隙。
            Positioned.fill(child: _buildVideo()),
            // 点按层放在视频之上、控制条之下：点画面切换控制条显隐。
            if (showChrome)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                ),
              ),
            if (showChrome)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: _chrome(_buildTopBar(episodeTitle)),
                ),
              ),
            if (showChrome)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  // 全屏横屏时不再避让底部安全区：控制条要完全贴底，
                  // 否则 Home 指示条那一条会在控件下方留出空隙。
                  bottom: !_fullscreen,
                  child: _chrome(_buildBottomBar(speed)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 控制条的淡入淡出 + 隐藏时不接收点击。
  Widget _chrome(Widget child) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: child,
      ),
    );
  }

  Widget _buildVideo() {
    if (_error != null) return _buildErrorView();
    final controller = _controller;
    final retained = _retained;
    final retainedReady = retained != null && retained.value.isInitialized;
    final currentReady =
        controller != null && controller.value.isInitialized && !_loading;
    // 固定两个插槽：旧帧在最底层、当前视频在第二层。旧帧释放时用
    // SizedBox 占住第 0 个位置，避免第二层的平台视图因为 children 下标变化
    // 被重建（iOS platformView 重建会闪一下黑）。
    return Stack(
      alignment: Alignment.center,
      children: [
        if (retainedReady)
          Center(
            child: AspectRatio(
              aspectRatio: _aspectOf(retained.value),
              child: VideoPlayer(retained),
            ),
          )
        else
          const SizedBox.shrink(),
        if (currentReady)
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) => Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: _aspectOf(value),
                    child: VideoPlayer(controller),
                  ),
                ),
                // seek / 弱网时画面会停住，没有反馈会以为卡死。
                if (value.isBuffering)
                  const SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
          )
        else if (!retainedReady || _showSpinner)
          _buildLoading()
        else
          const SizedBox.shrink(),
      ],
    );
  }

  double _aspectOf(VideoPlayerValue value) =>
      value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio;

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 14),
          Text(
            '正在准备视频…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    final failure = _error!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              failure.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              failure.reason,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: SelectableText(
                  failure.detail,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  onPressed: () => unawaited(_open(_index)),
                  child: const Text('重试'),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(_open(_index, refresh: true)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  child: const Text('重新下载这一集'),
                ),
                TextButton.icon(
                  onPressed: () => unawaited(_copyError()),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制错误信息'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(String episodeTitle) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            color: Colors.white,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.args.seriesTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  episodeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(double speed) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 30, 12, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final duration = value.duration;
          final position = value.position > duration
              ? duration
              : value.position;
          final maxMs = duration.inMilliseconds.toDouble();
          final shown = _dragValue == null
              ? position
              : Duration(milliseconds: _dragValue!.round());
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  min: 0,
                  max: maxMs <= 0 ? 1 : maxMs,
                  value: shown.inMilliseconds.toDouble().clamp(
                    0,
                    maxMs <= 0 ? 1 : maxMs,
                  ),
                  // 拖动中只改显示值，松手才真正 seek：每 tick 都 seek 会
                  // 对回环连发 Range 请求，真机会卡。
                  onChanged: (ms) {
                    _hideTimer?.cancel();
                    setState(() => _dragValue = ms);
                  },
                  onChangeEnd: (ms) {
                    setState(() => _dragValue = null);
                    _seekTo(Duration(milliseconds: ms.round()));
                    _scheduleHide();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Text(
                      _formatDuration(shown),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    // 倍速入口放在时间行而不是操作行：375pt/320pt 窄屏上
                    // 操作行左侧再塞一个 chip 会和「上一集」按钮重叠。
                    PlayerOptionChip(
                      label: playbackSpeedLabel(speed),
                      active: speed != 1.0,
                      tooltip: '播放速度',
                      onTap: () => unawaited(_openPlaybackSpeedSheet()),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _formatDuration(duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _openPrevious,
                          icon: const Icon(Icons.skip_previous_rounded),
                          color: _index > 0 ? Colors.white : Colors.white38,
                          iconSize: 30,
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          onPressed: _togglePlay,
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          iconSize: 30,
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: _openNext,
                          icon: const Icon(Icons.skip_next_rounded),
                          color: _index + 1 < _episodes.length
                              ? Colors.white
                              : Colors.white38,
                          iconSize: 30,
                        ),
                      ],
                    ),
                    // 左侧「选集」：像阅读器目录弹层一样快速跳集。
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: IconButton(
                          onPressed: () => unawaited(_openEpisodePicker()),
                          icon: const Icon(Icons.video_library_outlined),
                          color: Colors.white,
                          iconSize: 26,
                          tooltip: '选集',
                        ),
                      ),
                    ),
                    // 只有横屏视频才给全屏入口：竖屏内容全屏只会更小。
                    if (_isLandscapeVideo(value))
                      Positioned(
                        right: 0,
                        child: IconButton(
                          onPressed: () => unawaited(_toggleFullscreen()),
                          icon: Icon(
                            _fullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                          ),
                          color: Colors.white,
                          iconSize: 28,
                          tooltip: _fullscreen ? '退出全屏' : '全屏',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _formatDuration(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}

/// 一次播放失败的可展示信息。
class _PlaybackFailure {
  const _PlaybackFailure({
    required this.title,
    required this.reason,
    required this.detail,
  });

  /// 一句话标题（如「视频解码失败」）。
  final String title;

  /// 可能原因与建议动作。
  final String reason;

  /// 可复制的技术详情（集 id、地址、原始异常、堆栈前几行）。
  final String detail;
}
