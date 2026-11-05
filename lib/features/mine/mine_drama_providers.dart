import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/video_series.dart';

/// 一条短剧观看记录。
///
/// 与小说侧的 `ReadingProgress` 对齐：都只记「看到哪一集/哪一页 + 时间」，
/// 页面点进去直接续播。真正的本地存储（收藏/历史）还没实现，模型先定下来，
/// 后面接 `shared_preferences` 时页面不需要改结构。
@immutable
class DramaWatchProgress {
  const DramaWatchProgress({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.episodeIndex = 0,
    this.updatedAt,
  });

  final String seriesId;
  final String title;
  final String cover;

  /// 看到第几集（0-based）。
  final int episodeIndex;

  final DateTime? updatedAt;
}

/// 短剧侧「我的」快照，形状与小说侧的 `MineData` 对齐：
/// 收藏（对应书架）+ 最近观看（对应最近阅读）。
@immutable
class MineDramaData {
  const MineDramaData({required this.collections, required this.history});

  /// 收藏的短剧，按加入时间倒序。
  final List<VideoSeries> collections;

  /// 最近观看，按观看时间倒序。
  final List<DramaWatchProgress> history;
}

/// 短剧收藏 + 最近观看。
///
/// TODO(短剧存储): 收藏/观看进度落地后，这里改成和 `mineDataProvider` 一样
/// 依赖本地存储的 revision；现在返回空列表，先让「我的」页的双面板切换、
/// 镜像布局和空态跑通。
final mineDramaDataProvider = FutureProvider<MineDramaData>((ref) async {
  return const MineDramaData(collections: [], history: []);
});
