import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 我的页书架/收藏瀑布流的列数与列宽换算。
///
/// 小说与短剧两个 tab 共用一套规则，保证卡片宽度完全一致；宽屏（iPad）
/// 自动增列，避免封面被拉得过大。卡片高度不再预算——白底卡片按内容自然
/// 高度排版，高低差由 `MasonryGridView` 吸收。
class MineGridMetrics {
  const MineGridMetrics._({required this.columns, required this.itemWidth});

  /// 每块网格的左右留白（与推荐页/搜索框一致，都是 8）。
  static const _gutter = 8.0;

  /// 列间距（同时作为 MasonryGridView 的 crossAxisSpacing）。
  static const spacing = 8.0;

  /// 卡片目标宽度：手机（含 402pt 的 iPhone 17）保持 3 列，宽屏自动增列。
  ///
  /// 左右留白收到 8 后可用宽度变宽，阈值从 128 提到 132，避免 402pt 机型
  /// 因为 ceil(386 / 128) = 4 意外变成 4 列。
  static const _maxCardWidth = 132.0;

  final int columns;
  final double itemWidth;

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
    return MineGridMetrics._(columns: columns, itemWidth: itemWidth);
  }
}
