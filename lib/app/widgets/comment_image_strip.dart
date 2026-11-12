import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/comment_image.dart';
import 'comment_image_loader.dart';
import 'comment_image_viewer.dart';

/// 评论正文下方的配图缩略图。
///
/// 图片是评论的附属内容：单张给一个 4:3 的大图位，多张按正方形网格铺
/// （最多 [maxImages] 张，超出在最后一张上盖 `+N`）。点任意一张进全屏
/// 查看器（[_CommentThumbnail] → [showCommentImageViewer]）。
///
/// 缩略图取 [CommentImageRef.thumb]（上游有 `thumb_url` 时就是小图），并按
/// 格位物理像素解码（`memCacheWidth`，loader 用 ResizeImage）；全屏查看器才
/// 拿 [CommentImageRef.full] 原图。加载中/失败都退化成占位块，不会把整条
/// 评论撑坏。
class CommentImageStrip extends ConsumerWidget {
  const CommentImageStrip({
    super.key,
    required this.imageRefs,
    this.compact = false,
    this.placeholderColor,
  });

  final List<CommentImageRef> imageRefs;

  /// 回复区用紧凑尺寸（更小的格子、圆角）。
  final bool compact;

  /// 占位底色；阅读页评论面板传纸色前景的淡色，默认用主题 surface。
  final Color? placeholderColor;

  /// 单条评论最多画 9 张，多出来的用 `+N` 提示。
  static const int maxImages = 9;

  static const double _spacing = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refs = [
      for (final ref in imageRefs)
        if (ref.thumb.isNotEmpty || ref.full.isNotEmpty) ref,
    ];
    if (refs.isEmpty) return const SizedBox.shrink();
    // 缩略图格位用 thumb（缺失时退回原图），查看器永远拿原图。
    final thumbs = [
      for (final ref in refs) ref.thumb.isEmpty ? ref.full : ref.thumb,
    ];
    final fullUrls = [
      for (final ref in refs) ref.full.isEmpty ? ref.thumb : ref.full,
    ];
    final loader = ref.watch(commentImageLoaderProvider);
    final visible = math.min(refs.length, maxImages);
    final extra = refs.length - visible;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _tileSize(constraints.maxWidth, refs.length);
        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: [
            for (var index = 0; index < visible; index++)
              _CommentThumbnail(
                url: thumbs[index],
                size: size,
                loader: loader,
                compact: compact,
                placeholderColor: placeholderColor,
                overlayCount: index == visible - 1 && extra > 0 ? extra : null,
                index: index,
                total: refs.length,
                onTap: () => showCommentImageViewer(
                  context,
                  imageUrls: fullUrls,
                  initialIndex: index,
                ),
              ),
          ],
        );
      },
    );
  }

  Size _tileSize(double maxWidth, int count) {
    if (count <= 1) {
      if (compact) return const Size.square(76);
      final width = math.min(maxWidth * 0.66, 200.0);
      return Size(width, width * 0.75);
    }
    // 两张图并排；三张以上按三列正方形排，保证同一行高度一致。
    final columns = count == 2 ? 2 : 3;
    final available = maxWidth - _spacing * (columns - 1);
    final maxSide = compact ? 68.0 : (count == 2 ? 150.0 : 104.0);
    final side = math.min(available / columns, maxSide);
    return Size.square(side);
  }
}

class _CommentThumbnail extends StatelessWidget {
  const _CommentThumbnail({
    required this.url,
    required this.size,
    required this.loader,
    required this.compact,
    required this.placeholderColor,
    required this.overlayCount,
    required this.index,
    required this.total,
    required this.onTap,
  });

  final String url;
  final Size size;
  final CommentImageLoader loader;
  final bool compact;
  final Color? placeholderColor;
  final int? overlayCount;
  final int index;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final background = placeholderColor ?? scheme.surfaceContainerHighest;
    Widget placeholder({bool broken = false}) {
      return Container(
        width: size.width,
        height: size.height,
        color: background,
        alignment: Alignment.center,
        child: Icon(
          broken ? Icons.broken_image_outlined : Icons.image_outlined,
          size: compact ? 18 : 24,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      );
    }

    return Semantics(
      button: true,
      label: '查看评论图片 ${index + 1}/$total',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(compact ? 6 : 8),
          child: Stack(
            children: [
              Image(
                image: loader(url, memCacheWidth: (size.width * dpr).round()),
                width: size.width,
                height: size.height,
                fit: BoxFit.cover,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  return placeholder();
                },
                errorBuilder: (context, error, stackTrace) =>
                    placeholder(broken: true),
              ),
              if (overlayCount != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.5),
                    child: Center(
                      child: Text(
                        '+$overlayCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
