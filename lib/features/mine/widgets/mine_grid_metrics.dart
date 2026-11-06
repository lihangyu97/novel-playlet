import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../app/widgets/novel_cover.dart';

/// 我的页书架/收藏网格的尺寸换算。
///
/// 小说与短剧两侧共用一套规则，保证切换面板时卡片尺寸完全一致；宽屏
/// （iPad）自动增列，避免封面被拉得过大。
class MineGridMetrics {
  const MineGridMetrics._({
    required this.columns,
    required this.itemWidth,
    required this.itemHeight,
  });

  /// 每块网格的左右留白。
  static const _gutter = 16.0;

  /// 列间距（同时作为 GridView 的 crossAxisSpacing）。
  static const spacing = 12.0;

  /// 卡片目标宽度：手机 3 列、iPad 自动增列。
  static const _maxCardWidth = 128.0;

  final int columns;
  final double itemWidth;
  final double itemHeight;

  factory MineGridMetrics.of(BuildContext context) {
    final availableWidth = math.max(
      0.0,
      MediaQuery.sizeOf(context).width - _gutter * 2,
    );
    final columns = math.max(
      2,
      math.min(6, (availableWidth / _maxCardWidth).ceil()),
    );
    final itemWidth = math.max(
      0.0,
      (availableWidth - spacing * (columns - 1)) / columns,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    // 与 MediaCard 的内部排版对齐（封面 kCoverAspect 比例 + 标题两行 + 元信息
    // 一行），再按系统字体缩放留出高度，避免网格单元格比卡片矮造成溢出。
    return MineGridMetrics._(
      columns: columns,
      itemWidth: itemWidth,
      itemHeight:
          itemWidth * kCoverAspect +
          8 +
          textScaler.scale(14) * 1.25 * 2 +
          3 +
          textScaler.scale(12) * 1.35 +
          6,
    );
  }
}
