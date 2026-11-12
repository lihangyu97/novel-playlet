import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/novel_cover.dart';
import '../../data/models/chapter.dart';
import '../../data/models/video_series.dart';
import '../../data/models/video_source.dart';
import '../cache/cache_providers.dart';
import '../cache/offline_task.dart';
import '../cache/widgets/offline_download_button.dart';
import 'episode_source_resolver.dart';
import 'network_health.dart';
import 'offline_playback.dart';
import 'playback_failure.dart';
import 'playback_speed.dart';
import 'video_library_providers.dart';
import 'widgets/episode_picker_sheet.dart';
import 'widgets/playback_speed_sheet.dart';
import 'widgets/player_option_chip.dart';
import 'widgets/video_comments_sheet.dart';

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
      // 的 textureView（见 docs/implementation.md）。
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
/// 切集交互是整页竖向翻页（上滑下一集 / 下滑上一集，类似短视频 feed），
/// 不再提供上一集/下一集按钮。手指滑过一半只**预热**目标集（解析来源 +
/// initialize + 停在第一帧，不动当前播放）；翻页落定后才提交：预热命中就
/// 直接接管、首帧立即可见，滑回落定则丢弃预热、原集继续播放（不重播）。
/// 下一集的取流结果在当前集播 5s 后预取，已缓存集切换时看不到「正在准备
/// 视频」。
///
/// 后台/画中画/HDR 本轮不做（见 docs/implementation.md）：退后台不做显式
/// 暂停，回前台仍在播放就继续。
///
/// 方向：App 全局竖屏（`main.dart` 锁定），只有横屏视频（宽高比 > 1.05）才在
/// 播放页视频画面下方给出「全屏观看」提示，点了才临时放开横屏；退出全屏或
/// 离开播放页立刻恢复竖屏，避免横屏状态漏到其它页面。
class VideoPlayerPage extends ConsumerStatefulWidget {
  const VideoPlayerPage({super.key, required this.args});

  final VideoPlayArgs args;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage>
    with WidgetsBindingObserver {
  late int _index;

  VideoPlayerController? _controller;
  bool _loading = true;

  /// 播放失败的原因 + 可复制的技术详情。播放页的失败原因不止"网络"，也可能是
  /// 缓存文件半截、编码不支持、ATS 拦截，所以不能只给一句"请重试"。
  PlaybackFailure? _error;

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

  /// 同页重载（重试 / 重新下载）时垫底的上一帧：暂停留着画面，等新 controller
  /// 真正出画面再释放，避免黑一下。翻页切集不用它（见 [_pending]）。
  VideoPlayerController? _retained;

  /// 滑过半后预热的下一集 controller：已 initialize、暂停在第 0 帧。
  ///
  /// 预热不改变当前播放状态；翻页落定后 [_commitSettled] 才把它提升为当前
  /// controller。用户滑回原页则 [_cancelPending] 丢弃，原集继续播、不重播。
  VideoPlayerController? _pending;
  int? _pendingIndex;
  Future<void>? _pendingReady;
  int _prepareToken = 0;

  /// 手指拖动期间暂停当前集：滑走就换集，滑回原页再恢复播放，音画不抢。
  bool _pausedByDrag = false;

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

  /// 预取下一集的取流结果（episodeId → source）。预取走 `mode=stream`：内核
  /// 立即返回 `/src` 地址并在后台下载，把「上游往返 + 下载启动」移出关键路径，
  /// 切集只用拿现成的回环地址起播。
  final Map<String, VideoSource> _prefetched = {};
  final Set<String> _prefetching = {};
  Timer? _prefetchTimer;

  /// 竖向翻页控制器：上滑下一集 / 下滑上一集。
  late final PageController _pageController;

  /// 程序化翻页（选集弹层 / 播完自动续播）进行中：忽略 ScrollEndNotification，
  /// 由 [_changeEpisode] 自己 await 翻页结束后再加载目标集，避免重复 _open。
  bool _jumping = false;
  int? _programmaticTarget;

  /// 本次拖动是否已经按方向预热过目标集。方向在第一个 ScrollUpdate 才能
  /// 判断，所以预热不必等到滑过一半；早一点开始，相邻页更快出首帧。
  bool _dragPreheatStarted = false;

  /// 横屏判定：接近 1 的方图不算，避免给错按钮。
  static const double _landscapeAspect = 1.05;

  List<Chapter> get _episodes => widget.args.episodes;

  Chapter? get _episode =>
      _index >= 0 && _index < _episodes.length ? _episodes[_index] : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lastIndex = _episodes.isEmpty ? 0 : _episodes.length - 1;
    _index = widget.args.index < 0
        ? 0
        : (widget.args.index > lastIndex ? lastIndex : widget.args.index);
    _pageController = PageController(initialPage: _index);
    unawaited(_open(_index));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation += 1;
    _hideTimer?.cancel();
    _spinnerTimer?.cancel();
    _prefetchTimer?.cancel();
    _cancelSpeedReapplyTimers();
    _cancelPending();
    _disposeController();
    _disposeRetained();
    _pageController.dispose();
    // 带着全屏状态退出播放页时，下一次进别的页面还在横屏就糟了。
    if (_fullscreen) unawaited(_restorePortrait());
    super.dispose();
  }

  /// 旋转屏幕（进出全屏）会改变 PageView 的 viewport 高度，而 PageController
  /// 的 pixel offset 不会自动换算：横竖屏切换后不拉回当前页，就会停在半页上。
  /// 全屏横屏现在也能上下滑切集，这个校正尤其重要。
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _jumping ||
          _programmaticTarget != null ||
          _pausedByDrag) {
        return;
      }
      if (!_pageController.hasClients) return;
      final page = _pageController.page;
      if (page == null || (page - _index).abs() <= 0.01) return;
      _pageController.jumpToPage(_index);
    });
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

  /// [recovered] 只用于「回环监听被系统回收」的一次性恢复：调用方第一次
  /// 恢复重试时传 true，避免恢复本身失败后无限自愈。CONTRACTS 把自动重试
  /// 循环留给内核，页面这里只做一次有界恢复，不是退避重试。
  Future<void> _open(
    int index, {
    bool refresh = false,
    bool autoAdvance = false,
    bool recovered = false,
    bool retainPrevious = true,
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
    // 同页重载保留上一帧垫底；翻页落定后的兜底加载（预热失败/未预热）时
    // 旧页已经滑出屏幕，直接释放旧 controller，别让两个 AVPlayer 并存。
    _pausedByDrag = false;
    if (retainPrevious) {
      _retainCurrentController();
    } else {
      _disposeController();
      _disposeRetained();
    }
    String sourceUrl = '';
    String localPath = '';
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      // 控制条：自动续播不弹出来打断观看；其它切集/重试保持用户当前显隐
      // （正在沉浸观看就别因为滑了一集把控制条弹出来）。首次进入默认可见。
      if (autoAdvance) _controlsVisible = false;
      _dragValue = null;
      // 有上一帧垫底时先不闪 spinner：新画面往往 250ms 内就绪；没有垫底
      // （首次进入 / 预热失败兜底）才立即给加载反馈。
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
      // 取流级联（离线 → 预取 → 内核缓存 → stream → 整集下载）统一由
      // [EpisodeSourceResolver] 决定；正式起播传入 playNetworkUrl，让它在
      // 每个候选地址上真的起播、失败再回退下一级。
      final resolved =
          await _episodeSourceResolver(
            isCancelled: () => !mounted || generation != _generation,
          ).resolve(
            episodeId: episode.id,
            refresh: refresh,
            playNetworkUrl: (url) async {
              sourceUrl = url;
              await _startController(
                ref.read(playbackControllerFactoryProvider)(
                  networkUrl: Uri.parse(url),
                ),
                index: index,
                generation: generation,
                autoAdvance: autoAdvance,
              );
            },
          );
      // null = 已被更新的切集请求取代（generation 变了），直接丢弃。
      if (resolved == null) return;
      // 网络源在上面 playNetworkUrl 里已经起播；只有离线文件需要这里建
      // controller（本地明文 mp4 不碰内核）。
      if (!resolved.isLocal) return;
      localPath = resolved.file!.path;
      await _startController(
        ref.read(playbackControllerFactoryProvider)(file: resolved.file!),
        index: index,
        generation: generation,
        autoAdvance: autoAdvance,
      );
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      // iOS 长时间挂起后会回收回环监听（Apple TN2277）：内核 FFI 还活着，
      // 但 AVPlayer 连 127.0.0.1 被拒（-1004）。先探活/必要时整核重启，
      // 服务回来后把这一集重新打开一次；[recovered] 保证最多恢复一次。
      if (!recovered && isLoopbackConnectRefused(error)) {
        final restored = await ref.read(backendEnsureLoopbackProvider)();
        if (!mounted || generation != _generation) return;
        if (restored) {
          await _open(
            index,
            refresh: refresh,
            autoAdvance: autoAdvance,
            recovered: true,
          );
          return;
        }
      }
      _spinnerTimer?.cancel();
      _disposeRetained();
      // 没有离线副本、失败又像「网络不可达」：换成明确文案；网络在线时保留
      // 原来的失败原因（上游/鉴权/解码各有各的说明 + 重试入口）。
      final offlineLike =
          error is SuspectedOfflineException || isOfflineNetworkFailure(error);
      if (error is! SuspectedOfflineException &&
          isOfflineNetworkFailure(error)) {
        // 记住这次失败，后续切集不再重复等一次完整取流（见 NetworkHealth）。
        ref.read(networkHealthProvider).recordFailure();
      }
      final missedOffline = resolveOfflineEpisode(
        cachedFile: null,
        offline: offlineLike,
      );
      final failureContext = _failureContext(
        episode,
        sourceUrl: sourceUrl,
        localPath: localPath,
        refreshed: refresh,
      );
      setState(() {
        _loading = false;
        _showSpinner = false;
        _error = missedOffline.source == EpisodePlaybackSource.offlineMiss
            ? offlineMissPlaybackFailure(error, stack, context: failureContext)
            : describePlaybackFailure(error, stack, context: failureContext);
      });
    }
  }

  /// 组装一集的取流级联：把页面的 IO（离线副本 / 预取 / 内核缓存 / 取流）
  /// 与 [NetworkHealth] 接到 [EpisodeSourceResolver] 上。
  ///
  /// resolver 不持有 State：取消判定通过 [isCancelled] 注入，网络源是否真的
  /// 起播由调用方决定（正式起播传 `playNetworkUrl`；预热/预取只解析地址）。
  EpisodeSourceResolver _episodeSourceResolver({
    required bool Function() isCancelled,
  }) {
    final api = ref.read(apiClientProvider);
    final health = ref.read(networkHealthProvider);
    return EpisodeSourceResolver(
      loadOfflineFile: (episodeId, {required refresh}) =>
          _offlineFile(episodeId, refresh: refresh),
      takePrefetchedUrl: (episodeId) => _prefetched.remove(episodeId)?.url,
      probeCachedUrl: api.cachedVideoUrl,
      fetchSource: (episodeId, {required stream, required refresh}) => stream
          ? api.videoSource(episodeId, stream: true)
          : api.videoSource(episodeId, refresh: refresh),
      isSuspectedOffline: () => health.isSuspectedOffline,
      recordSuccess: health.recordSuccess,
      isCancelled: isCancelled,
    );
  }

  /// 失败文案的纯数据上下文（集信息 + 本次取源尝试）。
  PlaybackFailureContext _failureContext(
    Chapter episode, {
    required String sourceUrl,
    required String localPath,
    required bool refreshed,
  }) => PlaybackFailureContext(
    seriesTitle: widget.args.seriesTitle,
    episodeTitle: episode.title,
    episodeId: episode.id,
    episodeNumber: _index + 1,
    sourceUrl: sourceUrl,
    localPath: localPath,
    refreshed: refreshed,
  );

  /// 用户主动重试 / 重新下载：清掉「疑似离线」再走一次完整取流。
  ///
  /// 自动切集为了不重复等网络会短路，但用户点按钮就是明确要求再试一次，
  /// 这里必须把标记清掉，否则按钮会立刻被同一条短路逻辑挡回来。
  void _retry({bool refresh = false}) {
    ref.read(networkHealthProvider).clear();
    unawaited(_open(_index, refresh: refresh));
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
    await _attachReadyController(
      controller,
      index: index,
      generation: generation,
      autoAdvance: autoAdvance,
    );
  }

  /// initialize 之后的统一收尾：倍速/播放/进度/预取。
  ///
  /// 正常取流路径（[_startController]）与翻页预热路径（[_adoptPending]）共用，
  /// 避免两处各写一套起播逻辑。
  Future<void> _attachReadyController(
    VideoPlayerController controller, {
    required int index,
    required int generation,
    bool autoAdvance = false,
  }) async {
    // 新 controller 默认是 1.0x，切集/换源必须把全局倍速重新 apply 一次。
    // 暂停态调用只记值不下发，真正下发由随后的 play() 完成（插件语义）。
    await controller.setPlaybackSpeed(ref.read(playbackSpeedProvider));
    await controller.setLooping(false);
    if (!mounted || generation != _generation) {
      unawaited(controller.dispose());
      return;
    }
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
      // 重新下载这一集时只校正 manifest；`.part` 清理关掉——同一部剧可能正
      // 在后台离线下载，别把下载器的在写文件删掉（P1-1 的同一类竞态）。
      await store.reconcile(seriesId, cleanupParts: false);
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
        // 播完自动续播：整页滑到下一集，控制条保持隐藏（见 _open 的说明）。
        unawaited(_changeEpisode(_index + 1, autoAdvance: true));
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
  /// 预取请求 `mode=stream`：内核立即返回 `/src` 地址并开始后台下载下一集，
  /// 切集时直接拿现成地址起播，不再等上游往返 + 整集落盘。失败静默——切集时
  /// 还有正常取流兜底，不需要打扰用户。
  Future<void> _prefetchNext() async {
    final next = _index + 1;
    if (next >= _episodes.length) return;
    final episode = _episodes[next];
    if (episode.id.isEmpty) return;
    if (_prefetched.containsKey(episode.id) ||
        _prefetching.contains(episode.id)) {
      return;
    }
    // 刚发生过网络类失败就不预取：预取会触发整集下载，断网时只会白等一段
    // 内核重试预算；等切集真正命中网络成功后再恢复。
    if (ref.read(networkHealthProvider).isSuspectedOffline) return;
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
      // 预取只解析地址、不起播：交给同一个取流级联（内核缓存命中 → stream
      // → 整集下载兜底），拿到地址后存进页内 LRU。
      final resolved = await _episodeSourceResolver(isCancelled: () => !mounted)
          .resolve(episodeId: episode.id);
      if (resolved == null || resolved.isLocal) return;
      // 预取真的走了网络且成功时 resolver 已 recordSuccess；这里只记地址
      // （切集只用得到 url）。
      _rememberPrefetched(episode.id, VideoSource(url: resolved.url!));
    } catch (_) {
      // 预取失败静默：切集时走正常取流，失败原因由播放页统一展示。
    } finally {
      _prefetching.remove(episode.id);
    }
  }

  /// 记下预取结果。页内只留最近两条：追剧时无限积累没有意义。
  void _rememberPrefetched(String episodeId, VideoSource source) {
    while (_prefetched.length >= 2) {
      _prefetched.remove(_prefetched.keys.first);
    }
    _prefetched[episodeId] = source;
  }

  Future<void> _copyError() async {
    final error = _error;
    if (error == null) return;
    await Clipboard.setData(
      ClipboardData(text: '${error.title}\n${error.reason}\n${error.detail}'),
    );
    if (!mounted) return;
    showAppSnackBar(context, '错误信息已复制');
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
    await _changeEpisode(picked, animate: false);
  }

  /// 当前 PageView 停在的页码（翻页动画期间取动画中的中间页）。
  int get _currentPage => _pageController.hasClients
      ? (_pageController.page ?? _index).round()
      : _index;

  /// 整页切到第 [target] 集：先预热目标集，同时把页面滑过去；落定后统一
  /// 提交（预热还没完成就等它，落定页先显示占位/第一帧）。选集弹层的大跨集
  /// 跳转用 jump，播完自动续播用相邻页动画。
  Future<void> _changeEpisode(
    int target, {
    bool autoAdvance = false,
    bool animate = true,
  }) async {
    if (target < 0 || target >= _episodes.length || target == _index) return;
    if (!_pageController.hasClients) return;
    unawaited(_prepare(target));
    // 程序化翻页期间屏蔽手势回调；提交完再放开。
    _programmaticTarget = target;
    _jumping = true;
    try {
      try {
        if (!animate || (target - _currentPage).abs() > 1) {
          _pageController.jumpToPage(target);
        } else {
          await _pageController.animateToPage(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        }
      } finally {
        _jumping = false;
      }
      if (!mounted) return;
      await _commitSettled(target, autoAdvance: autoAdvance);
    } finally {
      _programmaticTarget = null;
    }
  }

  /// 用户滑过一半：只预热目标集（不暂停当前、不换 _index、不播放）；滑回
  /// 落定就丢弃。真正换集在 [_onPagerScrollNotification] 落定后提交。
  void _onPagerPageChanged(int index) {
    if (_jumping || _programmaticTarget != null) return;
    if (index == _index) {
      _cancelPending();
      return;
    }
    unawaited(_prepare(index));
  }

  /// 预热一集：解析来源 + initialize + 暂停在第 0 帧，不碰当前播放状态。
  ///
  /// 失败静默（[_pending] 为空），落定后由 [_commitSettled] 走 [_open] 的
  /// 错误展示与 -1004 恢复路径。
  Future<void> _prepare(int index) async {
    if (index < 0 || index >= _episodes.length || index == _index) return;
    if (index == _pendingIndex) {
      final ready = _pendingReady;
      if (ready != null) await ready;
      return;
    }
    _cancelPending();
    final token = ++_prepareToken;
    _pendingIndex = index;
    final ready = Completer<void>();
    _pendingReady = ready.future;
    // 预热状态要立刻反映到相邻页：PageView 拖动过程中不会重建已经建好的页，
    // 少了这次 setState，相邻页会一直停在拖动开始时构建的普通占位上，
    // 预热完成后也看不到首帧。
    if (mounted) setState(() {});
    final episode = _episodes[index];
    VideoPlayerController? controller;
    try {
      // 和正式起播同一条取流级联（离线 → 预取 → 内核缓存 → stream → 整集
      // 下载），但不传 playNetworkUrl：预热只解析地址，controller 由这里
      // 建好后停在第一帧。
      final resolved = await _episodeSourceResolver(
        isCancelled: () => !mounted || token != _prepareToken,
      ).resolve(episodeId: episode.id);
      if (resolved == null) return;
      controller = resolved.isLocal
          ? ref.read(playbackControllerFactoryProvider)(file: resolved.file!)
          : ref.read(playbackControllerFactoryProvider)(
              networkUrl: Uri.parse(resolved.url!),
            );
      await controller.initialize();
      if (!mounted || token != _prepareToken) {
        unawaited(controller.dispose());
        return;
      }
      // 预热只负责停在第一帧：倍速/播放等真正接管时由 _attachReadyController
      // 统一 apply。
      await controller.pause();
      if (!mounted || token != _prepareToken) {
        unawaited(controller.dispose());
        return;
      }
      _pending = controller;
      // 预热完成也不能等落定：拖动中的相邻页要立刻重建、渲染首帧
      // （[_buildEpisodePage] 看到 [_pending] 会换成真实视频画面）。
      if (mounted) setState(() {});
    } catch (_) {
      if (controller != null) unawaited(controller.dispose());
      if (token == _prepareToken) {
        _pending = null;
        if (mounted) setState(() {});
      }
    } finally {
      if (!ready.isCompleted) ready.complete();
    }
  }

  void _cancelPending() {
    _prepareToken++;
    final pending = _pending;
    _pending = null;
    _pendingIndex = null;
    _pendingReady = null;
    if (pending != null) unawaited(pending.dispose());
  }

  /// 用户开始拖动：暂停当前集（滑走就换集，滑回原页再恢复）。
  void _pauseForDrag() {
    if (_pausedByDrag) return;
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _pausedByDrag = true;
    _hideTimer?.cancel();
    unawaited(controller.pause());
  }

  void _resumeAfterCancelledDrag() {
    if (!_pausedByDrag) return;
    _pausedByDrag = false;
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isPlaying) {
      return;
    }
    unawaited(controller.play());
    _scheduleSpeedReapply(_generation);
    _scheduleHide();
  }

  /// PageView 滚动通知：拖动开始暂停、滑过一半预热、落定后提交/取消。
  ///
  /// 只认 PageView 自己的滚动：错误页里的 SingleChildScrollView 等内层滚动
  /// 会冒泡上来，depth != 0 一律忽略。
  bool _onPagerScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _dragPreheatStarted = false;
      if (notification.dragDetails != null) _pauseForDrag();
    } else if (notification is ScrollUpdateNotification) {
      // 方向一确定就预热目标集，不等滑过半：相邻页从拖动一开始就按
      // 「封面 → 首帧」的顺序出画面，滑到一半时通常已经能直接接上。
      if (!_dragPreheatStarted &&
          notification.dragDetails != null &&
          !_jumping &&
          _programmaticTarget == null) {
        final viewport = notification.metrics.viewportDimension;
        if (viewport > 0) {
          final offset = notification.metrics.pixels - _index * viewport;
          if (offset != 0) {
            _dragPreheatStarted = true;
            final target = offset > 0 ? _index + 1 : _index - 1;
            if (target >= 0 && target < _episodes.length) {
              unawaited(_prepare(target));
            }
          }
        }
      }
    } else if (notification is ScrollEndNotification) {
      _dragPreheatStarted = false;
      if (_jumping || _programmaticTarget != null) return false;
      final page = _pageController.hasClients
          ? _pageController.page?.round()
          : null;
      if (page == null) return false;
      if (page == _index) {
        _cancelPending();
        _resumeAfterCancelledDrag();
      } else {
        unawaited(_commitSettled(page));
      }
    }
    return false;
  }

  /// 翻页落定：预热命中就等它初始化完，直接提升为当前 controller；预热失败
  /// 或没有预热（程序化跳页等）才走原来的 [_open]（错误展示/恢复都在这）。
  Future<void> _commitSettled(int index, {bool autoAdvance = false}) async {
    _pausedByDrag = false;
    final ready = _pendingIndex == index ? _pendingReady : null;
    if (ready != null) {
      try {
        await ready;
      } catch (_) {
        // 预热内部已静默失败，下面按未命中处理。
      }
    }
    if (!mounted) return;
    final controller = _pendingIndex == index ? _pending : null;
    if (controller == null) {
      _cancelPending();
      await _open(index, retainPrevious: false, autoAdvance: autoAdvance);
      return;
    }
    _pending = null;
    _pendingIndex = null;
    _pendingReady = null;
    _adoptPending(controller, index: index, autoAdvance: autoAdvance);
  }

  /// 把预热好的 controller 提升为当前集：旧页已滑出屏幕，直接释放旧
  /// controller；预热 controller 已 initialize，首帧立即可见，不用再等加载。
  void _adoptPending(
    VideoPlayerController controller, {
    required int index,
    bool autoAdvance = false,
  }) {
    final generation = ++_generation;
    _advancing = false;
    _hideTimer?.cancel();
    _prefetchTimer?.cancel();
    _cancelSpeedReapplyTimers();
    _wasPlaying = false;
    _speedReapplyPending = false;
    _disposeController();
    _disposeRetained();
    setState(() {
      _index = index;
      _loading = false;
      _error = null;
      _dragValue = null;
      _showSpinner = false;
      if (autoAdvance) _controlsVisible = false;
      // 先挂上新 controller：画面/底部控制条立刻切到新集，不会塌陷一帧。
      _controller = controller;
    });
    unawaited(
      _attachReadyController(
        controller,
        index: index,
        generation: generation,
        autoAdvance: autoAdvance,
      ),
    );
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

  /// 当前剧的收藏项：从播放参数拼，收藏页展示标题/封面/集数就够。
  VideoSeries get _shelfItem => VideoSeries(
    id: widget.args.seriesId,
    title: widget.args.seriesTitle,
    cover: widget.args.cover,
    episodeCount: _episodes.length,
  );

  /// 收藏：只加不移（与阅读页顶部「加入书架」一致）。
  ///
  /// 历史「最近观看」是直进播放页的，这里没有入口的话看过就收藏不了；
  /// 已收藏后按钮变只读态，不再提供取消（取消入口在「我的 → 收藏」里）。
  /// 成功不弹提示条：图标自己会变成实心，底部操作行不该被 SnackBar 压住。
  Future<void> _addToShelf() async {
    final seriesId = widget.args.seriesId;
    if (seriesId.isEmpty || !_shelfItem.isValid) return;
    final provider = videoShelfStatusProvider(seriesId);
    if ((ref.read(provider).value ?? false) || ref.read(provider).isLoading) {
      return;
    }
    try {
      await ref.read(provider.notifier).add(_shelfItem);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(context, '收藏失败，请重试');
    }
  }

  /// 缓存整剧：未缓存 → 开始/续传；缓存中、已缓存 → 进缓存中心看进度。
  ///
  /// 三态判定和小说阅读页顶部「缓存小说」共用 [offlineEntryStatusProvider]，
  /// 两个入口不会各算一套。
  Future<void> _handleCacheTap() async {
    final args = widget.args;
    if (args.seriesId.isEmpty) return;
    final status = ref.read(
      offlineEntryStatusProvider((
        kind: OfflineTaskKind.video,
        id: args.seriesId,
      )),
    );
    if (status != OfflineEntryStatus.none) {
      await context.pushAppRoute(const CacheCenterRoute());
      return;
    }
    await startOfflineDownload(
      context,
      ref,
      kind: OfflineTaskKind.video,
      id: args.seriesId,
      title: args.seriesTitle,
      cover: args.cover,
      items: _episodes,
    );
  }

  /// 打开剧集详情。历史「最近观看」直进播放页，这是补回来的详情入口；
  /// 进详情前先暂停，返回后原来在播就继续播，避免详情页的播放按钮和这里
  /// 同时出声。
  Future<void> _openVideoDetail() async {
    final args = widget.args;
    if (args.seriesId.isEmpty) return;
    final wasPlaying = _controller?.value.isPlaying ?? false;
    if (wasPlaying) unawaited(_controller?.pause());
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
    try {
      await context.pushAppRoute(
        VideoDetailRoute(seriesId: args.seriesId, preview: _shelfItem),
      );
    } finally {
      if (mounted) {
        if (wasPlaying) unawaited(_controller?.play());
        _scheduleHide();
      }
    }
  }

  /// 本集评论：官方按集 vid 取的热评列表（一次最多 20 条），没有 vid 就不开。
  Future<void> _openEpisodeComments() async {
    final seriesId = widget.args.seriesId;
    final episode = _episode;
    if (seriesId.isEmpty || episode == null || episode.id.isEmpty) return;
    _hideTimer?.cancel();
    await showVideoCommentsSheet(context, seriesId: seriesId, vid: episode.id);
    if (mounted) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final episodeTitle = _episode?.title.isNotEmpty == true
        ? _episode!.title
        : '第 ${_index + 1} 集';
    // 加载期间也保留顶栏（返回键/剧名），不要整屏只剩 spinner。
    final showChrome = _error == null;
    // 全屏提示只给横屏视频：视频已经铺满整屏时（全屏）不需要，竖屏视频全屏
    // 只会更小，也不给入口。
    final showFullscreenHint = showChrome && !_fullscreen && _canFullscreen;
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
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 视频在 Center + AspectRatio 里居中铺开，画面高度 = 屏宽 / 宽高比，
            // 上下各留一条黑边。「全屏观看」提示要贴在真实画面下边缘 8px 处，
            // 不能按整屏底部摆，否则 16:9 视频下方会说远不近。
            final controller = _controller;
            final aspect = controller == null
                ? 16 / 9
                : _aspectOf(controller.value);
            final videoHeight = constraints.maxWidth / aspect;
            final hintTop =
                (constraints.maxHeight - videoHeight) / 2 + videoHeight + 8;
            return Stack(
              children: [
                // 视频铺满整屏：全屏横屏时也要盖住底部安全区（Home 指示条那一条），
                // 否则画面下方会留一道黑边。顶部控制条始终避让状态栏；底部控制条
                // 只在竖屏避让安全区——全屏横屏时贴到屏幕最底边，否则 Home 指示条
                // 那一条会在控件下面留出空隙。
                Positioned.fill(child: _buildPager(showChrome: showChrome)),
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
                // 全屏入口放在视频下方：控制条隐藏时一起淡出且不接收点击
                // （点画面应该唤出控制条，而不是误进全屏）。放在控制条之后，
                // 窄屏上提示与底部渐变区重叠时也能点到、不会被盖住。
                if (showFullscreenHint)
                  Positioned(
                    top: hintTop,
                    left: 0,
                    right: 0,
                    child: _chrome(Center(child: _buildFullscreenHint())),
                  ),
              ],
            );
          },
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

  /// 视频画面下方的全屏入口：图标 + 「全屏观看」，半透明胶囊。
  ///
  /// 竖屏下 16:9 画面只占屏幕中间一条，底部控制条离画面很远；入口贴着画面
  /// 下边缘更符合「放大这块画面」的直觉。
  Widget _buildFullscreenHint() {
    return Semantics(
      button: true,
      label: '全屏观看',
      child: GestureDetector(
        onTap: () => unawaited(_enterFullscreen()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.fullscreen_rounded, color: Colors.white70, size: 18),
              SizedBox(width: 6),
              Text(
                '全屏观看',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 竖向翻页：上滑下一集、下滑上一集。
  ///
  /// 当前页持有正在播放的 controller；滑过半后才预热目标页（暂停在第一帧），
  /// 落定后提交。全屏横屏时禁用翻页：那是对画面的聚焦查看，不是 feed 浏览。
  /// 当前页持有正在播放的 controller；拖动一开始按方向预热目标页（暂停在第
  /// 一帧），落定后提交。全屏横屏下也保留竖向翻页：横屏时同样上滑下一集 /
  /// 下滑上一集。
  Widget _buildPager({required bool showChrome}) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onPagerScrollNotification,
      child: PageView.builder(
        key: const ValueKey('video-episode-pager'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        physics: const PageScrollPhysics(),
        onPageChanged: _onPagerPageChanged,
        itemCount: _episodes.length,
        itemBuilder: (context, index) {
          final page = _buildEpisodePage(index);
          // 每一页都套同一层 GestureDetector（只让当前页响应点击）：落定
          // 提交时 _index 变化，若这里按「是否当前页」增删 wrapper，widget
          // 树类型会变，VideoPlayer 的 State/platform view 被重建，iOS 上会
          // 闪一下黑。「始终套、只换 onTap」保证子树原地更新。
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: index == _index && showChrome ? _toggleControls : null,
            child: page,
          );
        },
      ),
    );
  }

  Widget _buildEpisodePage(int index) {
    if (index == _index) {
      if (_error != null) return _buildErrorView();
      return _buildVideoPageBody(
        controller: _controller,
        retained: _retained,
        loading: _loading,
        showSpinner: _showSpinner,
      );
    }
    if (index == _pendingIndex && _pending != null) {
      // 预热页：滑入时直接显示新集第一帧；落定提升为当前页时用的是同一个
      // 子树结构，VideoPlayer 的 State/平台视图原地保留（iOS 不会闪黑）。
      return _buildVideoPageBody(
        controller: _pending,
        retained: null,
        loading: false,
        showSpinner: false,
      );
    }
    if (index == _pendingIndex) {
      // 预热还没就绪：轻量占位（不闪「正在准备视频」的大 spinner）。
      return _buildPendingPlaceholder(index);
    }
    return _buildEpisodePlaceholder(index);
  }

  /// 短剧目录的集标题本身常常就是「第 3 集」，占位里就不要再重复一遍集数。
  static bool _titleHasEpisodeNumber(String title) =>
      RegExp(r'^第\s*[0-9零一二三四五六七八九十百千]+\s*集').hasMatch(title);

  /// 非当前页的底：优先铺剧封面（暗化）给滑动预告，没有封面就黑底。
  /// 拖动刚开始、首帧还没就绪时，相邻页先显示封面而不是纯黑，滑动时能
  /// 同时看到当前集画面和下一集封面。
  Widget _buildEpisodeBackdrop({required Widget child}) {
    final cover = widget.args.cover;
    if (cover.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Center(child: child),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // 与全站共用封面组件：接 AppImageCache 磁盘缓存（列表页/详情页已下过
        // 的封面直接命中）、占位色与失败兜底。不再用 Image.network——它会
        // 各建一个图片 provider，滑动相邻页时白下一遍封面，断网则全黑。
        // 圆角置 0、铺满整页；加载中给黑底占位，保持原「封面暗化」观感。
        LayoutBuilder(
          builder: (context, constraints) => NovelCover(
            url: cover,
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            radius: 0,
            placeholderColor: Colors.black,
            fadeInDuration: Duration.zero,
          ),
        ),
        const ColoredBox(color: Color(0x99000000)),
        Center(child: child),
      ],
    );
  }

  /// 非当前页的占位：封面（或黑底）+ 集数/集名。不放 spinner，避免看起来
  /// 像在加载一个还没开始加载的页面。
  Widget _buildEpisodePlaceholder(int index) {
    final episode = _episodes[index];
    final title = episode.title.isNotEmpty ? episode.title : '第 ${index + 1} 集';
    // 标题已经是「第 N 集」时只渲染一次，避免黑底上出现两个「第 N 集」。
    final showIndexLine = !_titleHasEpisodeNumber(title);
    return _buildEpisodeBackdrop(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIndexLine)
              Text(
                '第 ${index + 1} 集',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            if (showIndexLine) const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  /// 统一的视频画面骨架：当前页与预热页共用，保证翻页落定切换时 widget
  /// 树结构一致、VideoPlayer 的 State/平台视图原地保留。
  Widget _buildVideoPageBody({
    required VideoPlayerController? controller,
    required VideoPlayerController? retained,
    required bool loading,
    required bool showSpinner,
  }) {
    final retainedReady = retained != null && retained.value.isInitialized;
    final currentReady =
        controller != null && controller.value.isInitialized && !loading;
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
        else if (showSpinner)
          _buildLoading()
        else
          const ColoredBox(color: Colors.black),
      ],
    );
  }

  /// 预热还没就绪的占位：封面（或黑底）+ 轻量 spinner + 集数，避免大
  /// spinner 文案在已缓存集上闪一下。
  Widget _buildPendingPlaceholder(int index) {
    final episode = _episodes[index];
    final title = episode.title.isNotEmpty ? episode.title : '第 ${index + 1} 集';
    final label = _titleHasEpisodeNumber(title)
        ? title
        : '第 ${index + 1} 集 · $title';
    return _buildEpisodeBackdrop(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white38,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
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
                FilledButton(onPressed: _retry, child: const Text('重试')),
                OutlinedButton(
                  onPressed: () => _retry(refresh: true),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  child: const Text('重新下载这一集'),
                ),
                // 错误页的内容可能占满整屏、上下滑会被内部滚动区吃掉，
                // 给明确的上一集/下一集出口，别让用户只能重试或开选集。
                if (_index > 0)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_changeEpisode(_index - 1)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                    ),
                    icon: const Icon(Icons.skip_previous_rounded, size: 16),
                    label: const Text('上一集'),
                  ),
                if (_index + 1 < _episodes.length)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_changeEpisode(_index + 1)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                    ),
                    icon: const Icon(Icons.skip_next_rounded, size: 16),
                    label: const Text('下一集'),
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
          // 历史「最近观看」直进播放页，详情页只能从这里回得去。
          if (widget.args.seriesId.isNotEmpty)
            IconButton(
              tooltip: '剧集详情',
              onPressed: () => unawaited(_openVideoDetail()),
              icon: const Icon(Icons.info_outline_rounded),
              color: Colors.white,
            ),
        ],
      ),
    );
  }

  /// 控制条上的纯图标按钮：暗色渐变上用白色，激活态用主题色。
  Widget _barIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      color: active ? scheme.primary : Colors.white,
      disabledColor: Colors.white38,
      iconSize: 24,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      // M3 的 IconButton 默认 48×48；这里收成 40×40，否则操作行在窄屏上
      // 会挤到暂停键。
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// 收藏按钮（播放页底栏）：状态与详情页共用同一个 provider。
  Widget _buildShelfButton() {
    final shelfAsync = ref.watch(
      videoShelfStatusProvider(widget.args.seriesId),
    );
    final onShelf = shelfAsync.value ?? false;
    // 首次读本地收藏表还没回来时禁用，避免「刚进页面就点」把已收藏的剧
    // 又加一遍（toggle 依据的初始值会是 null）。
    final busy = shelfAsync.isLoading && !shelfAsync.hasValue;
    return _barIconButton(
      icon: onShelf ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      tooltip: onShelf ? '已收藏' : '收藏',
      active: onShelf,
      // 只加不移：已收藏后按钮只读（与阅读页「已在书架」一致）。
      onTap: onShelf || busy ? null : () => unawaited(_addToShelf()),
    );
  }

  /// 缓存按钮（播放页底栏）：未缓存 / 缓存中 / 已缓存三态。
  Widget _buildCacheButton() {
    final status = ref.watch(
      offlineEntryStatusProvider((
        kind: OfflineTaskKind.video,
        id: widget.args.seriesId,
      )),
    );
    final (icon, tooltip) = switch (status) {
      OfflineEntryStatus.cached => (Icons.download_done_rounded, '已缓存'),
      OfflineEntryStatus.inProgress => (Icons.downloading_rounded, '缓存中'),
      OfflineEntryStatus.none => (Icons.download_outlined, '缓存'),
    };
    return _barIconButton(
      icon: icon,
      tooltip: tooltip,
      active: status != OfflineEntryStatus.none,
      onTap: () => unawaited(_handleCacheTap()),
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
              // 操作行：左侧「选集 + 本集评论」，中间播放/暂停，右侧
              // 「收藏 + 缓存 + 倍速」。用 Stack 而不是等宽 Row：倍速 pill 是
              // 固定宽度，等宽分组在 360 宽的机型上会挤到溢出；Stack 让暂停键
              // 始终居中，两侧按自身宽度靠边（≥360pt 不会互相压到）。
              SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton.filled(
                      onPressed: _togglePlay,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      iconSize: 30,
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _barIconButton(
                              icon: Icons.video_library_outlined,
                              tooltip: '选集',
                              onTap: () => unawaited(_openEpisodePicker()),
                            ),
                            if (widget.args.seriesId.isNotEmpty)
                              _barIconButton(
                                icon: Icons.chat_bubble_outline_rounded,
                                tooltip: '本集评论',
                                onTap: () => unawaited(_openEpisodeComments()),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.args.seriesId.isNotEmpty) ...[
                              _buildShelfButton(),
                              _buildCacheButton(),
                            ],
                            PlayerOptionChip(
                              label: playbackSpeedLabel(speed),
                              active: speed != 1.0,
                              tooltip: '播放速度',
                              onTap: () => unawaited(_openPlaybackSpeedSheet()),
                            ),
                          ],
                        ),
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
