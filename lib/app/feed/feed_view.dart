import 'package:flutter/material.dart';

import '../widgets/states.dart';
import 'feed_footer.dart';
import 'feed_section_title.dart';
import 'feed_state.dart';

/// 首页流的通用骨架：可选区块标题 + 列表 sliver + 底部状态。
///
/// 合并推荐页里小说/短剧/漫剧三个分类的页面逻辑几乎一样，差别只在卡片和
/// sliver（网格 vs 列表、卡片字段）。把"滚动控制、下拉刷新、滚动到底加载下一页、
/// 首屏补页、空态/加载/错误"都收在这里，页面只关心自己的数据和卡片。
class FeedView<T> extends StatefulWidget {
  const FeedView({
    super.key,
    required this.state,
    this.title,
    required this.sliverBuilder,
    required this.onLoadMore,
    required this.onRetryLoadMore,
    required this.emptyMessage,
    required this.emptyIcon,
    this.onRefresh,
  });

  final FeedState<T> state;

  /// 区块标题；null = 不画标题（合并推荐页的分类本身已经是标题）。
  final String? title;

  /// 列表主体（网格 / 列表），由页面按内容域决定。
  final Widget Function(BuildContext context, FeedState<T> state) sliverBuilder;

  final Future<void> Function() onLoadMore;
  final VoidCallback onRetryLoadMore;

  /// null = 这个页面没有下拉刷新。推荐页各分类都传；详情/我的等页面不传。
  final Future<void> Function()? onRefresh;

  final String emptyMessage;
  final IconData emptyIcon;

  @override
  State<FeedView<T>> createState() => _FeedViewState<T>();
}

class _FeedViewState<T> extends State<FeedView<T>> {
  final _scrollController = ScrollController();

  /// 距底部多远开始预取下一页。保持保守：内容只有一页半时放大阈值会让一次
  /// 拖动连翻好几页，新卡片连环插入的观感很像"列表在跳动"。
  static const double _loadMoreThreshold = 200;

  /// 上次做"补屏检查"时的条目数。只在条目数变化后检查一次，避免 loadingMore
  /// 之类的状态变化反复排队、上游返回重复页时空转。
  int _lastFillCheckCount = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 一屏都没填满时主动补下一页：此时页面根本滚不动，用户只能在空白处硬拖
  /// 才能触发下一页。
  void _scheduleViewportFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final data = widget.state;
      if (!data.hasMore ||
          data.loadingMore ||
          data.loadMoreError != null) {
        return;
      }
      if (data.items.length == _lastFillCheckCount) return;
      _lastFillCheckCount = data.items.length;
      if (_scrollController.position.maxScrollExtent > 0) return;
      widget.onLoadMore();
    });
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    if (notification.metrics.extentAfter > _loadMoreThreshold) return false;
    widget.onLoadMore();
    return false;
  }

  ScrollPhysics get _physics => widget.onRefresh == null
      ? const ClampingScrollPhysics()
      : const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        );

  Widget _wrapScrollable(Widget child) {
    final listened = NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: child,
    );
    final onRefresh = widget.onRefresh;
    if (onRefresh == null) return listened;
    return RefreshIndicator(onRefresh: onRefresh, child: listened);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleViewportFill();
    return _buildBody();
  }

  Widget _buildBody() {
    final data = widget.state;
    if (data.items.isEmpty) {
      return _wrapScrollable(
        CustomScrollView(
          controller: _scrollController,
          physics: _physics,
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyView(message: widget.emptyMessage, icon: widget.emptyIcon),
            ),
          ],
        ),
      );
    }

    return _wrapScrollable(
      CustomScrollView(
        controller: _scrollController,
        physics: _physics,
        slivers: [
          if (widget.title != null)
            SliverToBoxAdapter(
              child: FeedSectionTitle(title: widget.title!),
            ),
          widget.sliverBuilder(context, data),
          SliverToBoxAdapter(
            child: FeedFooter(
              loadingMore: data.loadingMore,
              error: data.loadMoreError,
              hasMore: data.hasMore,
              onRetry: widget.onRetryLoadMore,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
