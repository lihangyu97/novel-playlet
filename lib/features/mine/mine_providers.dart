import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/library_records.dart';
import '../../core/storage/reading_store.dart';

/// 「历史」列表最多展示的条数（小说与短剧混排，按最近一次阅读/观看倒序）。
const mineHistoryLimit = 3;

// ---------------------------------------------------------------------------
// revision 桥接：把 store 的 ValueNotifier 计数变成可 watch 的 provider
// ---------------------------------------------------------------------------

/// 把 [ReadingStore.shelfRevision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 只监听「书架内容」变更（加入 / 移出）：阅读页的进度落盘走
/// [recentRevisionProvider]，不会让收藏列表失效、进而重查库并重建整片网格
/// （CODE_REVIEW P1-5）。
final shelfRevisionProvider = NotifierProvider<ShelfRevision, int>(
  ShelfRevision.new,
);

class ShelfRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.shelfRevision.value;
    store.shelfRevision.addListener(onChanged);
    ref.onDispose(() => store.shelfRevision.removeListener(onChanged));
    return store.shelfRevision.value;
  }
}

/// 把 [ReadingStore.recentRevision] 桥接成可 watch 的计数。
///
/// 只监听「阅读进度」写入：书架内容的加入/移出不会让历史重读。
final recentRevisionProvider = NotifierProvider<RecentRevision, int>(
  RecentRevision.new,
);

class RecentRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.recentRevision.value;
    store.recentRevision.addListener(onChanged);
    ref.onDispose(() => store.recentRevision.removeListener(onChanged));
    return store.recentRevision.value;
  }
}

/// 短剧侧「收藏」变更计数。
final videoShelfRevisionProvider = NotifierProvider<VideoShelfRevision, int>(
  VideoShelfRevision.new,
);

class VideoShelfRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.videoShelfRevision.value;
    store.videoShelfRevision.addListener(onChanged);
    ref.onDispose(() => store.videoShelfRevision.removeListener(onChanged));
    return store.videoShelfRevision.value;
  }
}

/// 短剧侧「观看进度」变更计数。
final videoHistoryRevisionProvider =
    NotifierProvider<VideoHistoryRevision, int>(VideoHistoryRevision.new);

class VideoHistoryRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.videoHistoryRevision.value;
    store.videoHistoryRevision.addListener(onChanged);
    ref.onDispose(() => store.videoHistoryRevision.removeListener(onChanged));
    return store.videoHistoryRevision.value;
  }
}

/// 短剧侧的**聚合**计数：播放页存进度（换集/退出）后
/// `videoProgressProvider` 靠它刷新（见 `lib/features/video/`）。
final videoRevisionProvider = NotifierProvider<VideoRevision, int>(
  VideoRevision.new,
);

class VideoRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.videoRevision.value;
    store.videoRevision.addListener(onChanged);
    ref.onDispose(() => store.videoRevision.removeListener(onChanged));
    return store.videoRevision.value;
  }
}

// ---------------------------------------------------------------------------
// 「我的」页数据：历史 / 收藏（小说与短剧混排）
// ---------------------------------------------------------------------------

/// 历史（跨小说与短剧，按最近阅读/观看倒序）。
///
/// 订阅两个进度通道：任意一侧写进度都会让这一块刷新，收藏变更则不影响。
final mineHistoryProvider = FutureProvider<List<LibraryRecord>>((ref) async {
  ref.watch(recentRevisionProvider);
  ref.watch(videoHistoryRevisionProvider);
  return ref.watch(readingStoreProvider).history(limit: mineHistoryLimit);
});

/// 页头的「历史 N」：只算条数，不取行。
final mineHistoryCountProvider = FutureProvider<int>((ref) async {
  ref.watch(recentRevisionProvider);
  ref.watch(videoHistoryRevisionProvider);
  return ref.watch(readingStoreProvider).historyCount();
});

/// 收藏（跨小说与短剧，按加入时间倒序）。
///
/// 订阅两个收藏通道：任意一侧加/移收藏都会刷新，阅读进度则不影响。
final mineCollectionProvider = FutureProvider<List<LibraryRecord>>((
  ref,
) async {
  ref.watch(shelfRevisionProvider);
  ref.watch(videoShelfRevisionProvider);
  return ref.watch(readingStoreProvider).shelfRecords();
});
