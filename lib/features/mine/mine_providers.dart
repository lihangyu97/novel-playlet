import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/cache/app_cache.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/novel_item.dart';

/// 最近阅读区最多展示的本数（本地进度表按时间倒序取前 N 条）。
///
/// 统计行的「最近阅读 M 本」与列表保持一致，避免出现"统计 37 本、列表只
/// 看到 20 本"的割裂感。
const mineRecentLimit = 3;

/// 「我的」页需要的一份本地快照。
class MineData {
  const MineData({required this.shelf, required this.recent});

  /// 书架上的书，按加入时间倒序（存储层保证新加入的在前）。
  final List<NovelItem> shelf;

  /// 最近阅读，按阅读时间倒序。
  final List<ReadingProgress> recent;
}

/// 把 [ReadingStore.revision] 桥接成 Riverpod 可以 watch 的计数。
///
/// 存储层刻意不依赖状态管理，只暴露 revision（`ValueNotifier<int>`）；
/// 这里监听它并把变化写进 Notifier 状态，[mineDataProvider] 通过
/// `ref.watch` 依赖本 provider，于是「加入书架 / 移出书架 / 保存进度」后
/// 页面会自动重取数据，不需要命令式刷新，也不会把异步数据塞进 setState。
final readingRevisionProvider = NotifierProvider<ReadingRevision, int>(
  ReadingRevision.new,
);

class ReadingRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onRevisionChanged() => state = store.revision.value;
    store.revision.addListener(onRevisionChanged);
    ref.onDispose(() => store.revision.removeListener(onRevisionChanged));
    return store.revision.value;
  }
}

/// 书架 + 最近阅读。
final mineDataProvider = FutureProvider<MineData>((ref) async {
  // 依赖 revision：书架/进度一有写入就让本 provider 重新读取。
  ref.watch(readingRevisionProvider);
  final store = ref.watch(readingStoreProvider);
  final shelf = await store.shelf();
  final recent = await store.recent(limit: mineRecentLimit);
  return MineData(shelf: shelf, recent: recent);
});

/// 缓存占用（视频/封面/章节）。切到「我的」页时 invalidate 重算一次——
/// 视频缓存只有播放时才会增长，不重算就会一直停在进 App 时的数字。
final cacheUsageProvider = FutureProvider<CacheUsage>(
  (ref) => AppCache.instance.measure(),
);
