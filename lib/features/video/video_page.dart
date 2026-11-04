import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/states.dart';
import '../../data/models/video_series.dart';
import 'video_controller.dart';
import 'video_state.dart';
import 'widgets/video_card.dart';

/// 视频 tab：顶部搜索框 + 短剧推荐流；提交搜索后同页切成结果列表。
///
/// 结构照搬推荐页（搜索/列表共用一个 controller），但内容域不同：卡片是
/// 短剧（`series_id`），点进去是短剧详情再选集播放，不是小说阅读器。
class VideoPage extends ConsumerStatefulWidget {
  const VideoPage({super.key});

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// 距底部多远开始预取下一页。
  static const double _loadMoreThreshold = 480;
  static const double _bottomInset = 24;

  @override
  void initState() {
    super.initState();
    // 页面可能因切 tab 重建，但 provider 里的关键词还在：回填输入框，
    // 否则会出现"结果列表 + 空搜索框"的错位。
    final query = ref.read(videoSearchQueryProvider);
    if (query != null) _searchController.text = query;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    _searchFocus.unfocus();
    if (query.isEmpty) {
      _cancelSearch();
      return;
    }
    if (ref.read(videoSearchQueryProvider) == query) {
      // 同一关键词再次提交 = 重试。
      ref.invalidate(videoFeedControllerProvider);
      return;
    }
    ref.read(videoSearchQueryProvider.notifier).submit(query);
  }

  void _clearSearchInput() {
    _searchController.clear();
    if (ref.read(videoSearchQueryProvider) != null) {
      ref.read(videoSearchQueryProvider.notifier).cancel();
    }
  }

  void _cancelSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    ref.read(videoSearchQueryProvider.notifier).cancel();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(videoFeedControllerProvider.notifier).refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeVideoError(error))));
    }
  }

  void _retry() => ref.invalidate(videoFeedControllerProvider);

  void _retryLoadMore() =>
      ref.read(videoFeedControllerProvider.notifier).retryLoadMore();

  void _openDetail(VideoSeries item) {
    Navigator.of(context).pushNamed(
      AppRoutes.videoDetail,
      arguments: VideoDetailArgs(seriesId: item.id, preview: item),
    );
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    if (notification.metrics.extentAfter > _loadMoreThreshold) return false;
    ref.read(videoFeedControllerProvider.notifier).loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(videoFeedControllerProvider);
    final activeQuery = ref.watch(videoSearchQueryProvider);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: _VideoSearchField(
              controller: _searchController,
              focusNode: _searchFocus,
              onSubmitted: _submitSearch,
              onClear: _clearSearchInput,
              onCancel: _cancelSearch,
              showCancel: activeQuery != null,
            ),
          ),
          Expanded(child: _buildBody(async, activeQuery)),
        ],
      ),
    );
  }

  Widget _buildBody(AsyncValue<VideoFeedState> async, String? activeQuery) {
    final data = async.value;

    // 关键词已提交但结果还没回来：整页只留加载/错误，避免旧推荐流闪一下。
    if (activeQuery != null &&
        (data == null || !data.isSearchMode || data.query != activeQuery)) {
      if (async.hasError) {
        return ErrorView(
          message: describeVideoError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '搜索中…');
    }

    if (data == null) {
      if (async.hasError) {
        return ErrorView(
          message: describeVideoError(async.error!),
          onRetry: _retry,
        );
      }
      return const LoadingView(label: '正在加载短剧');
    }

    return data.isSearchMode ? _buildSearchResults(data) : _buildFeed(data);
  }

  Widget _buildFeed(VideoFeedState data) {
    if (data.items.isEmpty) {
      return _buildEmptyScroll(
        message: '暂时没有短剧推荐\n下拉刷新试试',
        icon: Icons.movie_outlined,
      );
    }
    return _buildScrollable(
      CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: const _SectionTitle(title: '短剧推荐'),
          ),
          _buildGrid(data.items),
          _buildFooter(data),
          const SliverToBoxAdapter(child: SizedBox(height: _bottomInset)),
        ],
      ),
    );
  }

  Widget _buildSearchResults(VideoFeedState data) {
    if (data.items.isEmpty) {
      return _buildEmptyScroll(
        message: '没有找到「${data.query}」\n换个剧名再试试',
        icon: Icons.search_off_rounded,
      );
    }
    return _buildScrollable(
      CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _SectionTitle(
              title: '搜索结果',
              subtitle: '${data.query} · ${data.items.length} 部',
            ),
          ),
          _buildGrid(data.items),
          _buildFooter(data),
          const SliverToBoxAdapter(child: SizedBox(height: _bottomInset)),
        ],
      ),
    );
  }

  Widget _buildGrid(List<VideoSeries> items) {
    final width = MediaQuery.sizeOf(context).width;
    const columns = 3;
    const horizontal = 16.0;
    const spacing = 12.0;
    final cellWidth = (width - horizontal * 2 - spacing * 2) / columns;
    final textScaler = MediaQuery.textScalerOf(context);
    final titleLine =
        textScaler.scale(Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14) *
        1.25;
    final metaLine =
        textScaler.scale(Theme.of(context).textTheme.bodySmall?.fontSize ?? 12) *
        1.4;
    final cellHeight = cellWidth * 4 / 3 + 8 + titleLine * 2 + 3 + metaLine + 6;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: horizontal),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 16,
          mainAxisExtent: cellHeight,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            return VideoCard(
              item: item,
              width: cellWidth,
              onTap: () => _openDetail(item),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }

  Widget _buildFooter(VideoFeedState data) {
    if (data.loadingMore) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final error = data.loadMoreError;
    if (error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Text(error, style: Theme.of(context).textTheme.bodySmall),
              TextButton(onPressed: _retryLoadMore, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (!data.hasMore && data.items.isNotEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Text(
              '没有更多了',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  Widget _buildEmptyScroll({required String message, required IconData icon}) {
    return _buildScrollable(
      CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(message: message, icon: icon),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollable(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: RefreshIndicator(onRefresh: _refresh, child: child),
    );
  }
}

/// 顶部搜索框。结构与推荐页一致（固定 48 高，图标/输入/清空同行居中），
/// 但留在视频 feature 内，避免跨 feature 依赖。
class _VideoSearchField extends StatelessWidget {
  const _VideoSearchField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onClear,
    required this.onCancel,
    required this.showCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final VoidCallback onCancel;
  final bool showCancel;

  static const double _height = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 清空按钮跟随输入内容出现/消失，所以自己监听 controller，不能等父级重建。
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Row(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(_height / 2),
              ),
              child: SizedBox(
                height: _height,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        textInputAction: TextInputAction.search,
                        onSubmitted: onSubmitted,
                        style: theme.textTheme.bodyMedium,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜短剧',
                          hintStyle: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    if (value.text.isNotEmpty)
                      IconButton(
                        onPressed: onClear,
                        icon: const Icon(Icons.cancel_rounded, size: 18),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (showCancel)
            TextButton(onPressed: onCancel, child: const Text('取消')),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
