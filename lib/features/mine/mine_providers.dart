import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/novel_item.dart';

/// 最近阅读区最多展示的本数（本地进度表按时间倒序取前 N 条）。
///
/// 统计行的「最近阅读 M 本」与列表保持一致，避免出现"统计 37 本、列表只
/// 看到 20 本"的割裂感。
const mineRecentLimit = 3;

/// 把 [ReadingStore.shelfRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 只监听「书架内容」变更（加入 / 移出）：阅读页每 400ms 的进度落盘走
/// [recentRevisionProvider]，不会让书架 provider 失效、进而重读
/// shared_preferences 并重建整片书架网格（CODE_REVIEW P1-5）。
final shelfRevisionProvider = NotifierProvider<ShelfRevision, int>(
  ShelfRevision.new,
);

class ShelfRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.shelfRevision.value;
    store.shelfRevision.addListener(onRevisionChanged);
    ref.onDispose(() => store.shelfRevision.removeListener(onRevisionChanged));
    return store.shelfRevision.value;
  }
}

/// 把 [ReadingStore.recentRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 只监听「阅读进度」写入：书架内容的加入/移出不会让最近阅读重读。
final recentRevisionProvider = NotifierProvider<RecentRevision, int>(
  RecentRevision.new,
);

class RecentRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.recentRevision.value;
    store.recentRevision.addListener(onRevisionChanged);
    ref.onDispose(() => store.recentRevision.removeListener(onRevisionChanged));
    return store.recentRevision.value;
  }
}

/// 把 [ReadingStore.videoRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 与小说侧细分通道的拆法不同，这里是短剧侧的**聚合**计数：播放页存进度
/// （换集/退出）后 `videoProgressProvider` 靠它刷新（见
/// `lib/features/video/video_library_providers.dart`）。「我的」页的收藏 /
/// 最近观看分别订阅更细的通道（见 `mine_drama_providers.dart`）。
final videoRevisionProvider = NotifierProvider<VideoRevision, int>(
  VideoRevision.new,
);

class VideoRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.videoRevision.value;
    store.videoRevision.addListener(onRevisionChanged);
    ref.onDispose(() => store.videoRevision.removeListener(onRevisionChanged));
    return store.videoRevision.value;
  }
}

/// 书架（按加入时间倒序，存储层保证新加入的在前）。
///
/// 只依赖 [shelfRevisionProvider]：阅读进度写入不会重新解码这张表。
final mineShelfProvider = FutureProvider<List<NovelItem>>((ref) async {
  ref.watch(shelfRevisionProvider);
  return ref.watch(readingStoreProvider).shelf();
});

/// 最近阅读（按阅读时间倒序）。
///
/// 只依赖 [recentRevisionProvider]：阅读时每次进度落盘只会让这一块刷新，
/// 书架网格与页头统计不受影响。
final mineRecentProvider = FutureProvider<List<ReadingProgress>>((ref) async {
  ref.watch(recentRevisionProvider);
  return ref.watch(readingStoreProvider).recent(limit: mineRecentLimit);
});
