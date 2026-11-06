import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/video_series.dart';
import 'mine_providers.dart';

/// 短剧侧「我的」快照，形状与小说侧的 `MineData` 对齐：
/// 收藏（对应书架）+ 最近观看（对应最近阅读）。
@immutable
class MineDramaData {
  const MineDramaData({required this.collections, required this.history});

  /// 收藏的短剧，按加入时间倒序。
  final List<VideoSeries> collections;

  /// 最近观看，按观看时间倒序，最多 [ReadingStore.videoHistoryLimit] 条。
  final List<VideoWatchProgress> history;
}

/// 短剧收藏 + 最近观看。
///
/// 和 [mineDataProvider] 一样依赖本地存储的 revision：但只看短剧侧的计数器
/// （[videoRevisionProvider]），收藏/观看进度一有写入就自动重取，看小说不会
/// 连带重读短剧收藏与历史。
final mineDramaDataProvider = FutureProvider<MineDramaData>((ref) async {
  ref.watch(videoRevisionProvider);
  final store = ref.watch(readingStoreProvider);
  final collections = await store.videoShelf();
  final history = await store.videoHistory();
  return MineDramaData(collections: collections, history: history);
});
