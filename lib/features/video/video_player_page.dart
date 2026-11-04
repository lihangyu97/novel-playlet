import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';

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
    _disposeController();
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

  Future<void> _open(int index, {bool refresh = false}) async {
    if (_episodes.isEmpty) return;
    final episode = _episodes[index];
    final generation = ++_generation;
    _advancing = false;
    _hideTimer?.cancel();
    _disposeController();
    String sourceUrl = '';
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _controlsVisible = true;
      _dragValue = null;
    });

    try {
      final api = ref.read(apiClientProvider);
      // 默认（非 stream）模式：内核先把整集下载进加密缓存再返回 /src 地址，
      // 所以这里会等一会儿；流式回环（M1）接入后这一步会变成秒开。
      final source = await api.videoSource(episode.id, refresh: refresh);
      sourceUrl = source.url;
      if (!mounted || generation != _generation) return;

      final controller = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        // 无弹幕叠加需求，平台视图底层就是 AVPlayerLayer：少一次逐帧纹理
        // 拷贝，发热和功耗更好。若真机上发现浮层被原生视图遮挡，可退回默认
        // 的 textureView（见 docs/video-playback.md 4.1）。
        viewType: VideoViewType.platformView,
      );
      await controller.initialize();
      if (!mounted || generation != _generation) {
        unawaited(controller.dispose());
        return;
      }
      await controller.setLooping(false);
      _controller = controller;
      setState(() => _loading = false);
      // 换集后方向可能变：全屏中切到竖屏视频要退回竖屏，否则画面缩成一条。
      if (_fullscreen && !_isLandscapeVideo(controller.value)) {
        unawaited(_exitFullscreen());
      }
      controller.addListener(_onTick);
      await controller.play();
      _scheduleHide();
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _describePlaybackError(
          error,
          stack: stack,
          episode: episode,
          sourceUrl: sourceUrl,
          refreshed: refresh,
        );
      });
    }
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    if (_advancing) return;
    // AVPlayer 没有可靠的 completed 流，用「播到尾部且不再前进」判定；
    // 留 250ms 容差，避免最后一帧的抖动误触发。
    if (value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 250) &&
        !value.isPlaying) {
      _advancing = true;
      if (_index + 1 < _episodes.length) {
        unawaited(_open(_index + 1));
      }
    }
  }

  /// 把播放异常翻译成"人话原因 + 可复制的技术详情"。
  ///
  /// 失败发生在两段：`videoSource`（内核取流/整集下载，抛 ApiException /
  /// TimeoutException）和 `controller.initialize()`（AVPlayer，抛
  /// PlatformException，msg 里带 AVFoundation 的 `Code=-xxxxx`）。
  _PlaybackFailure _describePlaybackError(
    Object error, {
    required StackTrace stack,
    required Chapter episode,
    required String sourceUrl,
    required bool refreshed,
  }) {
    final raw = error.toString();
    final rawLower = raw.toLowerCase();
    String title;
    String reason;

    if (error is TimeoutException) {
      title = '取流超时';
      reason = '等内核下载/解密这一集超过 120 秒。常见于网络慢、上游限速，或这一集体积过大。';
    } else if (error is ApiException) {
      title = '取流失败';
      reason = error.message;
    } else if (error is PlatformException) {
      final text = [
        error.code,
        error.message ?? '',
        error.details?.toString() ?? '',
      ].join(' | ');
      if (RegExp(r'-1022|App Transport Security').hasMatch(text)) {
        title = '本地视频流被 ATS 拦截';
        reason = 'iOS 拒绝了 http://127.0.0.1 的回环请求（Info.plist 的 ATS 例外没生效）。';
      } else if (RegExp(
        r'-1001|-1005|-1009|-1011|-1012|-1200|-1202',
      ).hasMatch(text)) {
        title = '本地视频流连接中断';
        reason =
            'AVPlayer 读本地回环流时断开了：常见于内核下载被中断（App 切后台）、'
            '或回环服务被系统回收。点「重新下载这一集」重试。';
      } else if (RegExp(
        r'-1102|-11800|-11828|-11829|avfoundationerrordomain|decode|format',
        caseSensitive: false,
      ).hasMatch(text)) {
        title = '视频解码失败';
        reason =
            '这一集的文件可能损坏（半截缓存）或编码不受支持。'
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

    final frames = stack.toString().split('\n').take(4).join('\n');
    final detail = [
      '《${widget.args.seriesTitle}》第 ${_index + 1} 集 ${episode.title}（id=${episode.id}）',
      if (sourceUrl.isNotEmpty) '播放地址: $sourceUrl',
      if (refreshed) '本次为「重新下载这一集」后的结果',
      '错误类型: ${error.runtimeType}',
      '原始错误: $raw',
      if (frames.isNotEmpty) '堆栈(前 4 行):\n$frames',
    ].join('\n');
    return _PlaybackFailure(title: title, reason: reason, detail: detail);
  }

  Future<void> _copyError() async {
    final error = _error;
    if (error == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: '${error.title}\n${error.reason}\n${error.detail}',
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('错误信息已复制')));
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
    unawaited(controller.seekTo(position));
  }

  void _openPrevious() {
    if (_index <= 0) return;
    unawaited(_open(_index - 1));
  }

  void _openNext() {
    if (_index + 1 >= _episodes.length) return;
    unawaited(_open(_index + 1));
  }

  @override
  Widget build(BuildContext context) {
    final episodeTitle = _episode?.title.isNotEmpty == true
        ? _episode!.title
        : '第 ${_index + 1} 集';
    final showChrome = !_loading && _error == null;
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
            // 否则画面下方会留一道黑边。避让交给各自的 SafeArea 处理：
            // 视频不避让、控制条避让。
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
                child: SafeArea(top: false, child: _chrome(_buildBottomBar())),
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
    final controller = _controller;
    if (_error != null) return _buildErrorView();
    if (_loading || controller == null || !controller.value.isInitialized) {
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
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
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

  Widget _buildBottomBar() {
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
