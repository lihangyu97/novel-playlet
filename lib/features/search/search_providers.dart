import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/feed_page.dart';
import '../../data/models/hot_search.dart';
import '../../data/models/search_cue.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_item.dart';

/// 搜索页当前关键词；null = 还没提交过，页面显示引导空态。
///
/// autoDispose：搜索页关闭后自动清空，下次进来是一次干净的新搜索，也不会
/// 把搜索词漏到推荐页去（推荐页是纯推荐流）。
final searchQueryProvider =
    NotifierProvider.autoDispose<SearchQueryController, String?>(
      SearchQueryController.new,
    );

class SearchQueryController extends Notifier<String?> {
  @override
  String? build() => null;

  /// 提交关键词；空白关键词等同清空（回到引导空态）。
  void submit(String raw) {
    final query = raw.trim();
    state = query.isEmpty ? null : query;
  }

  void clear() => state = null;
}

/// 一次搜索请求的完整身份：分类 + 关键词。
///
/// 关键词放进 family 参数而不是控制器内部字段：换关键词就是换一个 provider
/// 实例，旧关键词迟到的响应只会写回旧的（已无人监听的）实例，不会覆盖新结果。
/// 这比在控制器里维护 generation 计数器更直接；旧实例随 autoDispose 一起回收。
@immutable
class SearchRequest {
  const SearchRequest({required this.category, required this.query});

  final RecommendCategory category;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is SearchRequest &&
      other.category == category &&
      other.query == query;

  @override
  int get hashCode => Object.hash(category, query);
}

/// 单个分类的搜索结果（首屏一页；横向卡片行只展示这一页）。
///
/// 搜索页的分类各自一个 provider 并行请求，页面按 小说 → 短剧 顺序各画一行
///（漫剧不单列：见 `SearchPage.searchCategories` 的说明）。
/// 关掉 Riverpod 3 的默认自动重试（10 次、约 38 秒）：搜索失败要立刻给用户
/// 「重试」入口，而不是在后台默默转圈，期间页面既看不到错误也点不到重试。
///
/// 只取首屏一页：上游 `next_offset` 暂时不用，卡片行到底就停住（v1 不做
/// 「查看更多」/横向加载下一页，后续要加时在这里接 offset）。
final searchResultsProvider = FutureProvider.autoDispose
    .family<FeedPage<RecommendItem>, SearchRequest>(
      (ref, request) => request.category.source.search(
        ref.read(apiClientProvider),
        request.query,
      ),
      retry: (retryCount, error) => null,
    );

/// 搜索框轮播热词（cue）。失败一律返回空：热词是装饰，不能阻断搜索。
///
/// 不用 autoDispose：一组词在 App 生命周期内复用，推荐页与搜索页共享同一份，
/// 打开搜索页时才能从推荐页当前轮播到的那条接着显示。
final searchCueProvider = FutureProvider<SearchCue>((ref) async {
  try {
    return await ref.read(apiClientProvider).searchCue();
  } catch (_) {
    return SearchCue.empty;
  }
});

/// 空搜索页的热搜榜（官方 472 热搜榜，最多 50 条，页面最多铺前 30）。
///
/// 进程级缓存：首页首屏完成后会预取一份，打开搜索页直接有内容；搜索页每次
/// 打开时由 [ensureFresh] 按 TTL 决定是否后台刷新。失败保留旧值/空榜，
/// 搜索历史仍然可用，热搜只是引导内容，不能把搜索页卡在错误态。
final hotSearchProvider = NotifierProvider<HotSearchController, HotSearch>(
  HotSearchController.new,
);

class HotSearchController extends Notifier<HotSearch> {
  /// 热搜榜变化慢，10 分钟内不重复请求；TTL 到了先展示旧数据再后台刷新。
  static const ttl = Duration(minutes: 10);

  DateTime? _fetchedAt;
  Future<void>? _inFlight;

  @override
  HotSearch build() {
    unawaited(_load());
    return HotSearch.empty;
  }

  /// 页面打开/预热入口：缓存新鲜就什么都不做，过期才拉。
  Future<void> ensureFresh({bool force = false}) async {
    final inFlight = _inFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final fetchedAt = _fetchedAt;
    if (!force &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < ttl) {
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    final existing = _inFlight;
    if (existing != null) {
      await existing;
      return;
    }
    final future = _fetch();
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<void> _fetch() async {
    try {
      final hot = await ref.read(apiClientProvider).hotSearch();
      if (!ref.mounted) return;
      state = hot;
      _fetchedAt = DateTime.now();
    } catch (_) {
      // 保留上一次成功的热搜榜；首次失败就是空榜，页面走搜索历史。
    }
  }
}
