import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/video_series.dart';

/// 把 [ReadingStore.videoShelfRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 只监听「收藏」变更：播放页存观看进度走
/// [videoHistoryRevisionProvider]，不会让收藏重读并重建收藏网格
/// （CODE_REVIEW P1-5 的短剧侧同构修法）。
final videoShelfRevisionProvider = NotifierProvider<VideoShelfRevision, int>(
  VideoShelfRevision.new,
);

class VideoShelfRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.videoShelfRevision.value;
    store.videoShelfRevision.addListener(onRevisionChanged);
    ref.onDispose(
      () => store.videoShelfRevision.removeListener(onRevisionChanged),
    );
    return store.videoShelfRevision.value;
  }
}

/// 把 [ReadingStore.videoHistoryRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 只监听「观看进度」写入：收藏的加入/移出不会让最近观看重读。
final videoHistoryRevisionProvider =
    NotifierProvider<VideoHistoryRevision, int>(VideoHistoryRevision.new);

class VideoHistoryRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.videoHistoryRevision.value;
    store.videoHistoryRevision.addListener(onRevisionChanged);
    ref.onDispose(
      () => store.videoHistoryRevision.removeListener(onRevisionChanged),
    );
    return store.videoHistoryRevision.value;
  }
}

/// 收藏的短剧（按加入时间倒序）。
///
/// 只依赖 [videoShelfRevisionProvider]：观看进度写入不会重新解码这张表。
final mineDramaShelfProvider = FutureProvider<List<VideoSeries>>((ref) async {
  ref.watch(videoShelfRevisionProvider);
  return ref.watch(readingStoreProvider).videoShelf();
});

/// 最近观看（按观看时间倒序，最多 [ReadingStore.videoHistoryLimit] 条）。
///
/// 只依赖 [videoHistoryRevisionProvider]：收藏变更不会让这一块重读。
final mineDramaHistoryProvider = FutureProvider<List<VideoWatchProgress>>((
  ref,
) async {
  ref.watch(videoHistoryRevisionProvider);
  return ref.watch(readingStoreProvider).videoHistory();
});
