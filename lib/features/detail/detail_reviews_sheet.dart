import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/states.dart';
import '../../data/models/book_comment.dart';
import '../../data/models/json_utils.dart';
import 'detail_providers.dart';
import 'detail_reviews_section.dart';

/// 打开「全部书评」底部弹层。
///
/// [initialPage] 是详情页已经拿到的第一页：有它就先铺列表，避免打开弹层时
/// 先闪一下 loading；后续翻页由弹层自己按 offset 续拿。
Future<void> showDetailReviewsSheet(
  BuildContext context, {
  required String bookId,
  BookCommentPage? initialPage,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) =>
        DetailReviewsSheet(bookId: bookId, initialPage: initialPage),
  );
}

/// 全部书评弹层：列表 + offset 翻页（每页 [bookReviewsPageSize] 条）。
class DetailReviewsSheet extends ConsumerStatefulWidget {
  const DetailReviewsSheet({super.key, required this.bookId, this.initialPage});

  final String bookId;
  final BookCommentPage? initialPage;

  @override
  ConsumerState<DetailReviewsSheet> createState() => _DetailReviewsSheetState();
}

class _DetailReviewsSheetState extends ConsumerState<DetailReviewsSheet> {
  final ScrollController _scrollController = ScrollController();
  final List<BookComment> _comments = <BookComment>[];

  int _totalCount = 0;
  int _nextOffset = 0;
  bool _hasMore = false;

  /// 首屏加载（只有没带 initialPage 时才可能走到）。
  bool _loading = false;

  /// 翻页请求进行中；用来禁用重复触发并显示列表底部转圈。
  bool _loadingMore = false;

  /// 首屏失败文案；非 null 时整页显示错误 + 重试。
  String? _error;

  /// 翻页失败文案；非 null 时列表底部显示重试（已加载的内容保留）。
  String? _loadMoreError;

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
    _nextOffset = page.nextOffset;
    _hasMore = page.hasMore;
    _loadMoreError = null;
  }

  /// 首屏请求：没有详情页传来的第一页时自己拉一次。
  Future<void> _loadFirstPage() async {
    try {
      final page = await ref
          .read(apiClientProvider)
          .bookComments(widget.bookId, count: bookReviewsPageSize);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _adopt(page);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = apiErrorCopy(error, fallback: '书评加载失败，请重试');
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
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 提前约一屏的高度开始加载：等用户真的滚到底时下一页通常已经在路上。
    if (position.pixels >= position.maxScrollExtent - 240) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _loadMoreError != null) return;
    setState(() => _loadingMore = true);
    final offset = _nextOffset;
    try {
      final page = await ref
          .read(apiClientProvider)
          .bookComments(
            widget.bookId,
            count: bookReviewsPageSize,
            offset: offset,
          );
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _comments.addAll(page.comments);
        if (page.totalCount > 0) _totalCount = page.totalCount;
        // 上游的 has_more 不完全可信：next_offset 没前进（或本页为空）就当作
        // 到底，避免滚动到底时反复拉同一页、列表无限增长。
        final advanced = page.nextOffset > offset;
        _nextOffset = advanced
            ? page.nextOffset
            : offset + page.comments.length;
        _hasMore = page.hasMore && page.comments.isNotEmpty && advanced;
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
    return AppBottomSheet(
      title: '书评',
      subtitle: _totalCount > 0 ? '共 $_totalCount 条' : null,
      // 约 0.8 屏高：一屏能看五六条书评，同时留出上方详情页作为上下文。
      heightFactor: 0.8,
      closeTooltip: '关闭书评',
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _retryFirstPage);
    }
    if (_comments.isEmpty) {
      return const EmptyView(message: '还没有书评', icon: Icons.forum_outlined);
    }
    final hasFooter = _loadingMore || _loadMoreError != null;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _comments.length + (hasFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _comments.length) return _buildFooter();
        return Column(
          children: [
            DetailReviewRow(
              comment: _comments[index],
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            ),
            if (index < _comments.length - 1 || hasFooter)
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
