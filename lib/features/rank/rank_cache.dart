import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/rank.dart';

/// 一份榜首屏缓存的 key。
///
/// 只缓存 offset=0 的第一页；翻页数据仍由页面自己的 FeedState 管。
@immutable
class RankBoardCacheKey {
  const RankBoardCacheKey({
    required this.rankId,
    required this.algo,
    required this.genreTab,
    this.categoryId = 0,
    this.offset = 0,
  });

  final String rankId;
  final int algo;
  final int genreTab;
  final int categoryId;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is RankBoardCacheKey &&
      other.rankId == rankId &&
      other.algo == algo &&
      other.genreTab == genreTab &&
      other.categoryId == categoryId &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(rankId, algo, genreTab, categoryId, offset);
}

@immutable
class RankBoardCacheEntry {
  const RankBoardCacheEntry({required this.board, required this.fetchedAt});

  final RankBoard board;
  final DateTime fetchedAt;
}

/// 排行榜榜首屏的进程内缓存。
///
/// 首页首屏完成后预取默认榜第一页，进排行榜页时先画缓存、再按 TTL 决定是否
/// 后台刷新。只留第一页，内存很小；图片仍然只存 URL，由全局图片缓存负责。
class RankBoardCache extends ChangeNotifier {
  /// 榜单变化不快，5 分钟内直接复用；过期后先画旧数据再刷新。
  static const ttl = Duration(minutes: 5);

  final Map<RankBoardCacheKey, RankBoardCacheEntry> _entries = {};

  RankBoardCacheEntry? read(RankBoardCacheKey key) => _entries[key];

  bool isFresh(RankBoardCacheEntry entry, {DateTime? now}) =>
      (now ?? DateTime.now()).difference(entry.fetchedAt) < ttl;

  void write(RankBoardCacheKey key, RankBoard board, {DateTime? fetchedAt}) {
    if (board.entries.isEmpty) return;
    _entries[key] = RankBoardCacheEntry(
      board: board,
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}

final rankBoardCacheProvider = Provider<RankBoardCache>((ref) {
  final cache = RankBoardCache();
  ref.onDispose(cache.dispose);
  return cache;
});
