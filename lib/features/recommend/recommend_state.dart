import 'package:flutter/foundation.dart';

import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';

/// 首页当前展示的是推荐流还是搜索结果。
///
/// 模式放在数据状态里而不是页面的 setState 里：切换模式要连带重置分页
/// 游标，交给 controller 一起处理才不会出现"搜索页拿着推荐流 offset"
/// 这种串味。
enum RecommendMode { feed, search }

/// 推荐页数据快照。
///
/// 首屏加载/失败由 `AsyncValue` 承载；这个类只描述"已经有数据、正在追加
/// 下一页"这些页面内状态，所以翻页失败不会清空已经展示的卡片。
@immutable
class RecommendState {
  const RecommendState._({
    required this.mode,
    required this.query,
    required this.items,
    this.nextOffset,
    this.sessionId,
    this.loadingMore = false,
    this.loadMoreError,
  });

  /// 推荐流：没有关键词，翻页必须回传 [sessionId]。
  factory RecommendState.feed({
    required List<NovelItem> items,
    int? nextOffset,
    String? sessionId,
  }) => RecommendState._(
    mode: RecommendMode.feed,
    query: '',
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
  );

  /// 搜索结果：关键词即上下文，翻页只带 offset。
  factory RecommendState.search({
    required String query,
    required List<NovelItem> items,
    int? nextOffset,
  }) => RecommendState._(
    mode: RecommendMode.search,
    query: query,
    items: items,
    nextOffset: nextOffset,
  );

  final RecommendMode mode;
  final String query;
  final List<NovelItem> items;

  /// 上游给的下一页游标，null 表示到底。
  final int? nextOffset;

  /// 推荐流的会话 id。只对推荐流有意义，搜索结果恒为 null。
  final String? sessionId;

  final bool loadingMore;

  /// 加载下一页失败的文案；列表保留，只在底部提示重试。
  final String? loadMoreError;

  bool get isSearchMode => mode == RecommendMode.search;

  bool get hasMore => nextOffset != null && nextOffset! > 0;

  bool get isEmpty => items.isEmpty;

  RecommendState withLoadingMore(bool value) => RecommendState._(
    mode: mode,
    query: query,
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
    loadingMore: value,
  );

  RecommendState withLoadMoreError(String? message) => RecommendState._(
    mode: mode,
    query: query,
    items: items,
    nextOffset: nextOffset,
    sessionId: sessionId,
    loadMoreError: message,
  );

  /// 追加一页并按 id 去重。
  ///
  /// 推荐流是拼接式的，同一本书可能同时出现在"榜单"和"猜你喜欢"两个区块，
  /// 所以去重必须跨页做，不能只依赖单页内的去重。
  RecommendState appendPage(NovelFeedPage page) {
    final seen = <String>{for (final item in items) item.id};
    final merged = List<NovelItem>.of(items);
    for (final item in page.items) {
      if (seen.add(item.id)) merged.add(item);
    }
    // 游标没前进就当作到底，避免同一个 offset 被反复请求把列表刷爆。
    final advanced =
        page.nextOffset != null && page.nextOffset! > (nextOffset ?? 0);
    return RecommendState._(
      mode: mode,
      query: query,
      items: merged,
      nextOffset: advanced ? page.nextOffset : null,
      sessionId: page.sessionId ?? sessionId,
    );
  }
}

/// 把异常变成可以直接展示的一句话：ApiException 的 message 已经是人话。
String describeFeedError(Object error) {
  if (error is ApiException) return error.message;
  return '网络开小差了，请稍后重试';
}
