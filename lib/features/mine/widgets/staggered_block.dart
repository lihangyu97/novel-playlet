import 'package:flutter/material.dart';

/// 每块在时间轴上占 60%（300ms），相邻块错开 20%（100ms）。
const _panelBlockWindow = 0.6;
const _panelBlockDelay = 0.2;

/// 单块内容的阶梯位移动画。
///
/// 时间轴 0..1 表示「小说 → 短剧」的进度：
/// - 第 [index] 块从 `index * 0.2` 开始、耗时 `0.6`（= 300ms）；
/// - 最近块 index=0（0ms）、标题 index=1（100ms）、书架/收藏 index=2（200ms）；
/// - 出场的块往左滑出，入场的块从右侧滑入。
class StaggeredBlock extends StatelessWidget {
  const StaggeredBlock({
    super.key,
    required this.progress,
    required this.index,
    required this.incoming,
    required this.child,
  });

  final Animation<double> progress;
  final int index;
  final bool incoming;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final start = index * _panelBlockDelay;
        final value = ((progress.value - start) / _panelBlockWindow).clamp(
          0.0,
          1.0,
        );
        final dx = incoming ? width * (1 - value) : -width * value;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}
