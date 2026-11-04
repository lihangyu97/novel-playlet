import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter.dart';

/// 播放页：AVPlayer（`video_player`）播放内核解密后的本地 HTTP 流。
///
/// 一集一个 controller：切集就换 controller（换档/换集都走同一条路），
/// 播放中的 controller 不跨集复用——AVPlayer 对同一 item 换源不如重建稳。
///
/// 后台/画中画/HDR 本轮不做（见 docs/video-playback.md）：退后台由
/// `video_player` 的默认行为暂停，回前台不自动恢复，用户点播放继续。
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
  String? _error;

  /// 异步换集的结果校验：用户连续点下一集时，旧请求回来必须丢弃。
  int _generation = 0;

  /// 播完自动下一集只触发一次（完成事件会重复到达）。
  bool _advancing = false;

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
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(controller.dispose());
    }
  }

  Future<void> _open(int index) async {
    if (_episodes.isEmpty) return;
    final episode = _episodes[index];
    final generation = ++_generation;
    _advancing = false;
    _disposeController();
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiClientProvider);
      // 默认（非 stream）模式：内核先把整集下载进加密缓存再返回 /src 地址，
      // 所以这里会等一会儿；流式回环（M1）接入后这一步会变成秒开。
      final source = await api.videoSource(episode.id);
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
      controller.addListener(_onTick);
      await controller.play();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _describePlaybackError(error);
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

  String _describePlaybackError(Object error) {
    final text = '$error';
    if (text.contains('403') || text.contains('404')) {
      return '视频地址已过期，请返回重新进入';
    }
    return '视频播放失败，请重试';
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      unawaited(controller.pause());
    } else {
      if (_advancing) {
        _advancing = false;
      }
      unawaited(controller.play());
    }
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildVideo()),
            if (!_loading && _error == null) _buildTopBar(episodeTitle),
            if (!_loading && _error == null) _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (_error != null) {
      return Center(
        child: ErrorView(
          message: _error!,
          onRetry: () => unawaited(_open(_index)),
        ),
      );
    }
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
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio == 0
            ? 16 / 9
            : controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildTopBar(String episodeTitle) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
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
      ),
    );
  }

  Widget _buildBottomBar() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
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
            final position = value.position > duration ? duration : value.position;
            final maxMs = duration.inMilliseconds.toDouble();
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
                    value: position.inMilliseconds
                        .toDouble()
                        .clamp(0, maxMs <= 0 ? 1 : maxMs),
                    onChanged: (ms) =>
                        _seekTo(Duration(milliseconds: ms.round())),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Text(
                        _formatDuration(position),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
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
              ],
            );
          },
        ),
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
