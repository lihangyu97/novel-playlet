import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/widgets/states.dart';
import '../../../data/models/book_comment.dart';
import '../../../data/models/json_utils.dart';
import '../../detail/detail_reviews_section.dart';
import '../video_comments_providers.dart';

/// 打开短剧评论弹层。
///
/// [vid] 为空 = 整部剧的「剧评」（cursor 翻页）；非空 = 当前这一集的评论
/// （官方按 vid 的热评，一次最多 20 条，没有翻页）。
///
/// [initialPage] 是详情页已经拿到的第一页：有它就先铺列表，避免打开弹层
/// 时先闪一下 loading。
Future<void> showVideoCommentsSheet(
  BuildContext context, {
  required String seriesId,
  String vid = '',
  BookCommentPage? initialPage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      // 约 0.8 屏高：一屏能看五六条评论，同时留出上方页面作为上下文。
      heightFactor: 0.8,
      child: VideoCommentsSheet(
        seriesId: seriesId,
        vid: vid,
        initialPage: initialPage,
      ),
    ),
  );
}

/// 短剧评论弹层：剧评（cursor 翻页）/ 本集评论（单页）共用一套列表。
class VideoCommentsSheet extends ConsumerStatefulWidget {
  const VideoCommentsSheet({
    super.key,
    required this.seriesId,
    this.vid = '',
    this.initialPage,
  });

  final String seriesId;
  final String vid;
  final BookCommentPage? initialPage;

  @override
  ConsumerState<VideoCommentsSheet> createState() => _VideoCommentsSheetState();
}

class _VideoCommentsSheetState extends ConsumerState<VideoCommentsSheet> {
  final ScrollController _scrollController = ScrollController();
  final List<BookComment> _comments = <BookComment>[];

  int _totalCount = 0;
  String _cursor = '';
  bool _hasMore = false;

  /// 首屏加载（只有没带 initialPage 时才可能走到）。
  bool _loading = false;

  /// 翻页请求进行中；用来禁用重复触发并显示列表底部转圈。
  bool _loadingMore = false;

  /// 首屏失败文案；非 null 时整页显示错误 + 重试。
  String? _error;

  /// 翻页失败文案；非 null 时列表底部显示重试（已加载的内容保留）。
  String? _loadMoreError;

  bool get _isEpisode => widget.vid.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    final initial = widget.initialPage;
    if (initial != null && initial.comments.isNotEmpty) {
      _adopt(initial);
    } else {
      _loading = true;
      unawaited(_loadFirstPage());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 用一页数据重置列表状态：首屏（含传入的初始页）与重试共用。
  void _adopt(BookCommentPage page) {
    _comments
      ..clear()
      ..addAll(page.comments);
    _totalCount = page.totalCount > 0 ? page.totalCount : page.comments.length;
    _cursor = page.cursor;
    // 本集评论（热评）没有 cursor，不做翻页。
    _hasMore = !_isEpisode && page.hasMore;
    _loadMoreError = null;
  }

  Future<BookCommentPage> _fetch({String cursor = ''}) {
    final api = ref.read(apiClientProvider);
    if (_isEpisode) {
      return api.episodeComments(widget.seriesId, widget.vid);
    }
    return api.seriesComments(
      widget.seriesId,
      count: videoCommentsPageSize,
      cursor: cursor,
    );
  }

  Future<void> _loadFirstPage() async {
    try {
      final page = await _fetch();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _adopt(page);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = apiErrorCopy(
          error,
          fallback: _isEpisode ? '本集评论加载失败，请重试' : '剧评加载失败，请重试',
        );
      });
    }
  }

  void _retryFirstPage() {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_loadFirstPage());
  }

  void _handleScroll() {
    if (!_hasMore || _loadingMore || _loadMoreError != null) return;
    if (!_scrollController.hasClients) return;
    // 离底部还有一屏约 0.3 时预取，滚动不会在页尾卡一下。
    if (_scrollController.position.extentAfter > 240) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final cursor = _cursor;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetch(cursor: cursor);
      if (!mounted) return;
      final before = _comments.length;
      final seen = <String>{
        for (final comment in _comments)
          if (comment.id.isNotEmpty) comment.id,
      };
      for (final comment in page.comments) {
        // cursor 重叠时上游会重复给同一条，按 id 去重，避免列表里出现两遍。
        if (comment.id.isNotEmpty && !seen.add(comment.id)) continue;
        _comments.add(comment);
      }
      final added = _comments.length - before;
      // cursor 不前进 / 没有新条目就停，防止上游忽略 cursor 时死循环。
      final advanced = page.cursor.isNotEmpty && page.cursor != cursor;
      setState(() {
        _loadingMore = false;
        _totalCount = page.totalCount > 0 ? page.totalCount : _totalCount;
        _cursor = page.cursor;
        _hasMore = page.hasMore && advanced && added > 0;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = apiErrorCopy(error, fallback: '加载失败，请重试');
      });
    }
  }

  void _retryLoadMore() {
    setState(() => _loadMoreError = null);
    unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = _isEpisode ? '本集评论' : '剧评';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _totalCount > 0 ? '共 $_totalCount 条' : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭评论',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _retryFirstPage);
    }
    if (_comments.isEmpty) {
      return EmptyView(
        message: _isEpisode ? '本集还没有评论' : '还没有剧评',
        icon: Icons.forum_outlined,
      );
    }
    final showFooter = !_isEpisode && (_loadingMore || _loadMoreError != null);
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: _comments.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _comments.length) return _buildFooter();
        return Column(
          children: [
            DetailReviewRow(
              comment: _comments[index],
              // 短剧评论没有评分字段，画一排空星反而像没加载出来。
              showStars: false,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            ),
            if (index < _comments.length - 1 || showFooter)
              const Divider(height: 1, indent: 66, endIndent: 20),
          ],
        );
      },
    );
  }

  Widget _buildFooter() {
    final error = _loadMoreError;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: error != null
            ? TextButton(onPressed: _retryLoadMore, child: const Text('重试'))
            : const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }
}
