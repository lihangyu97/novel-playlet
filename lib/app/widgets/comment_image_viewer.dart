import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'comment_image_loader.dart';

/// 打开评论配图的全屏查看器。
///
/// [imageUrls] 必须是原图地址（`CommentImageRef.full`）：缩略图列表只负责
/// 展示小图，点开才按整屏宽度解码一次原图。
///
/// 多张图左右滑或点左右箭头切换；任意一张都能双指缩放，单击画面任意处
/// 或右上角关闭，系统返回同样可退出。
///
/// 不绑双击放大：`onTap` 和 `onDoubleTap` 同时存在时，Flutter 必须等双击
/// 判定超时（约 300ms）才触发单击，点一下关闭会有肉眼可见的延迟；这里优先
/// 保证「点哪都立刻关」，放大交给双指捏合。
Future<void> showCommentImageViewer(
  BuildContext context, {
  required List<String> imageUrls,
  int initialIndex = 0,
}) {
  final urls = [
    for (final url in imageUrls)
      if (url.trim().isNotEmpty) url,
  ];
  if (urls.isEmpty) return Future<void>.value();
  final index = initialIndex.clamp(0, urls.length - 1);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, animation, secondaryAnimation) =>
          CommentImageViewer(imageUrls: urls, initialIndex: index),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// 全屏评论配图：黑底、左右切换、捏合/双击缩放。
class CommentImageViewer extends ConsumerStatefulWidget {
  const CommentImageViewer({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
  });

  final List<String> imageUrls;
  final int initialIndex;

  @override
  ConsumerState<CommentImageViewer> createState() => _CommentImageViewerState();
}

class _CommentImageViewerState extends ConsumerState<CommentImageViewer> {
  static const double _swipeThreshold = 56;

  late int _index;
  final TransformationController _controller = TransformationController();

  Offset? _pointerStart;
  Offset? _pointerLast;
  int _pointerCount = 0;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller.addListener(_handleTransformChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleTransformChanged() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _showImage(int index) {
    final next = index.clamp(0, widget.imageUrls.length - 1);
    if (next == _index) return;
    // 换图前复位缩放，否则新图会继承上一张的平移矩阵。
    _controller.value = Matrix4.identity();
    setState(() => _index = next);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerCount++;
    if (_pointerCount == 1) {
      _pointerStart = event.position;
      _pointerLast = event.position;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_pointerCount == 1) _pointerLast = event.position;
  }

  void _handlePointerEnd() {
    _pointerCount = math.max(0, _pointerCount - 1);
    if (_pointerCount > 0) return;
    final start = _pointerStart;
    final last = _pointerLast;
    _pointerStart = null;
    _pointerLast = null;
    if (_zoomed || start == null || last == null) return;
    final dx = last.dx - start.dx;
    final dy = last.dy - start.dy;
    // 只接管明确横向的滑动：纵向滑动留给手势返回/其它交互。
    if (dx.abs() < _swipeThreshold || dx.abs() < dy.abs() * 1.2) return;
    _showImage(dx < 0 ? _index + 1 : _index - 1);
  }

  @override
  Widget build(BuildContext context) {
    final loader = ref.watch(commentImageLoaderProvider);
    final urls = widget.imageUrls;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: (_) => _handlePointerEnd(),
                onPointerCancel: (_) => _handlePointerEnd(),
                child: GestureDetector(
                  // 只绑 onTap：单击立即关闭，不再等双击仲裁。缩放只保留
                  // InteractiveViewer 的双指捏合。
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: Semantics(
                    label: '评论图片 ${_index + 1}/${urls.length}',
                    image: true,
                    child: ValueListenableBuilder<Matrix4>(
                      valueListenable: _controller,
                      builder: (context, matrix, child) {
                        return InteractiveViewer(
                          transformationController: _controller,
                          minScale: 1,
                          maxScale: 4,
                          // 1x 时把平移让给外层左右滑切图；放大后才在图片内拖动。
                          panEnabled: matrix.getMaxScaleOnAxis() > 1.01,
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                      child: SizedBox.expand(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: KeyedSubtree(
                            key: ValueKey<int>(_index),
                            child: _buildImage(loader, urls[_index]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    tooltip: '关闭图片',
                    onPressed: () => Navigator.of(context).pop(),
                    color: Colors.white,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ),
            if (_index > 0)
              _SideArrow(
                alignment: Alignment.centerLeft,
                icon: Icons.chevron_left_rounded,
                tooltip: '上一张',
                onPressed: () => _showImage(_index - 1),
              ),
            if (_index < urls.length - 1)
              _SideArrow(
                alignment: Alignment.centerRight,
                icon: Icons.chevron_right_rounded,
                tooltip: '下一张',
                onPressed: () => _showImage(_index + 1),
              ),
            if (urls.length > 1)
              SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        '${_index + 1} / ${urls.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(CommentImageLoader loader, String url) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return Image(
      image: loader(url, memCacheWidth: (viewportWidth * dpr).round()),
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return const Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white24,
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: Colors.white38, size: 40),
            SizedBox(height: 10),
            Text('图片加载失败', style: TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

class _SideArrow extends StatelessWidget {
  const _SideArrow({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            color: Colors.white,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.35),
            ),
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}
