import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/comment_image_strip.dart';
import '../../data/api/api_client.dart';
import '../../data/models/book_comment.dart';
import '../../data/models/comment_reply.dart';

/// 打开阅读页的评论面板（只读）。
///
/// 段评和章末评论共用这一套：调用方只给「哪本书/哪一章/哪一段」这组定位参数，
/// 首屏、翻页、回复懒加载都在面板内部完成。面板不写任何接口——点赞、回复都只
/// 展示，避免阅读页为了一个弹层持有写操作状态。
///
/// [paper] 决定弹层底色和文字色（夜间/护眼纸色下弹层不能还是白底），
/// [title] 与 [totalCount] 只用于标题区，真实总数会在首屏响应后按上游修正。
Future<void> showReaderCommentsSheet(
  BuildContext context, {
  required ReaderPaper paper,
  required String bookId,
  required String chapterId,
  required String itemVersion,
  required int paraIndex,
  required String title,
  required int totalCount,
}) async {
  await showAppBottomSheet<void>(
    context: context,
    builder: (_) => ReaderCommentsSheet(
      paper: paper,
      bookId: bookId,
      chapterId: chapterId,
      itemVersion: itemVersion,
      paraIndex: paraIndex,
      title: title,
      totalCount: totalCount,
    ),
  );
}

/// 评论面板本体。拆成独立 public widget 是为了可读性；调用方走
/// [showReaderCommentsSheet] 即可，不需要直接构造它。
class ReaderCommentsSheet extends ConsumerStatefulWidget {
  const ReaderCommentsSheet({
    super.key,
    required this.paper,
    required this.bookId,
    required this.chapterId,
    required this.itemVersion,
    required this.paraIndex,
    required this.title,
    required this.totalCount,
  });

  final ReaderPaper paper;
  final String bookId;
  final String chapterId;
  final String itemVersion;
  final int paraIndex;
  final String title;
  final int totalCount;

  @override
  ConsumerState<ReaderCommentsSheet> createState() =>
      _ReaderCommentsSheetState();
}

/// 一条评论的回复区状态：展开/收起 + 懒加载结果。
///
/// 回复按需加载，收起时不销毁结果；再次展开直接复用，避免每次点击都打接口。
class _ReplyState {
  bool expanded = false;
  bool loading = false;
  bool loaded = false;
  Object? error;
  List<CommentReply> replies = const <CommentReply>[];
}

class _ReaderCommentsSheetState extends ConsumerState<ReaderCommentsSheet> {
  static const int _pageSize = 20;
  static const int _replyPageSize = 10;

  /// 距底部不到一屏的 1/3 时预取下一页；用常量而不是按高度计算，滚动监听里
  /// 不需要做布局查询。
  static const double _loadMoreThreshold = 300;

  final ScrollController _scrollController = ScrollController();

  /// key 用评论 id；上游偶尔不给 id，退回对象身份，保证不同评论的回复区不串。
  final Map<String, _ReplyState> _replies = <String, _ReplyState>{};

  List<BookComment> _comments = const <BookComment>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _firstPageError;
  Object? _loadMoreError;
  int _totalCount = 0;

  ApiClient get _api => ref.read(apiClientProvider);

  @override
  void initState() {
    super.initState();
    _totalCount = widget.totalCount;
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  /// 接近底部才取下一页。失败后不再自动重试：滚动会反复触发，必须等用户点
  /// footer 的重试，否则一次断网会连打多个请求。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter > _loadMoreThreshold) return;
    _loadMore();
  }

  Future<BookCommentPage> _fetchPage({String cursor = ''}) {
    return _api.paragraphComments(
      widget.bookId,
      widget.chapterId,
      paraIndex: widget.paraIndex,
      itemVersion: widget.itemVersion,
      count: _pageSize,
      cursor: cursor,
    );
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _firstPageError = null;
      _loadMoreError = null;
      _hasMore = false;
      _cursor = '';
    });
    try {
      final page = await _fetchPage();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _comments = List<BookComment>.unmodifiable(page.comments);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _applyTotal(page.totalCount);
      });
      _scheduleAutoFill();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _firstPageError = error;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    // 失败后只允许 footer 的重试入口再打；滚动不重复触发。
    if (_loadMoreError != null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _comments = _appendUnique(_comments, page.comments);
        // 游标没前进说明上游已经到底（或本轮没有新数据）：继续翻会原地打转，
        // 直接收住 hasMore，footer 才能显示「没有更多了」。
        final advanced = page.cursor.isNotEmpty && page.cursor != _cursor;
        _cursor = page.cursor;
        _hasMore = page.hasMore && advanced;
        _applyTotal(page.totalCount);
      });
      _scheduleAutoFill();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = error;
      });
    }
  }

  void _retryLoadMore() {
    if (_loadMoreError == null) return;
    setState(() => _loadMoreError = null);
    _loadMore();
  }

  /// 首屏不足一屏时不会有滚动事件，用户会以为没有更多；这里主动补一页。
  void _scheduleAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _loadingMore) return;
      if (!_hasMore || _loadMoreError != null) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter > _loadMoreThreshold) return;
      _loadMore();
    });
  }

  /// 按 id 去重后追加：上游翻页偶有重复条目，直接拼会重复渲染同一条评论。
  List<BookComment> _appendUnique(
    List<BookComment> current,
    List<BookComment> incoming,
  ) {
    final ids = <String>{
      for (final comment in current)
        if (comment.id.isNotEmpty) comment.id,
    };
    final merged = <BookComment>[...current];
    for (final comment in incoming) {
      if (comment.id.isNotEmpty && !ids.add(comment.id)) continue;
      merged.add(comment);
    }
    return List<BookComment>.unmodifiable(merged);
  }

  void _applyTotal(int total) {
    if (total > 0) _totalCount = total;
  }

  String _commentKey(BookComment comment) => comment.id.isNotEmpty
      ? comment.id
      : 'object-${identityHashCode(comment)}';

  void _toggleReplies(BookComment comment) {
    final key = _commentKey(comment);
    final state = _replies.putIfAbsent(key, () => _ReplyState());
    if (state.expanded) {
      setState(() => state.expanded = false);
      return;
    }
    setState(() => state.expanded = true);
    if (!state.loaded && !state.loading) _loadReplies(comment, state);
  }

  Future<void> _loadReplies(BookComment comment, _ReplyState state) async {
    setState(() {
      state.loading = true;
      state.error = null;
    });
    try {
      final page = await _api.commentReplies(
        comment.id,
        bookId: widget.bookId,
        // 段评回复按「章节」归组，group_id 就是章节 itemId。
        groupId: widget.chapterId,
        count: _replyPageSize,
      );
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.loaded = true;
        state.replies = page.replies;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.error = error;
      });
    }
  }

  void _retryReplies(BookComment comment, _ReplyState state) {
    if (state.loading) return;
    _loadReplies(comment, state);
  }

  @override
  Widget build(BuildContext context) {
    // 弹层挂 root Navigator，拿不到阅读页内部的局部主题；这里按纸色明暗和
    // 全局主题色重建一套，保证夜间模式/强调色下的对比度与阅读页一致。
    final brightness = widget.paper == ReaderPaper.night
        ? Brightness.dark
        : Brightness.light;
    final theme = Theme.of(context).copyWith(
      colorScheme: AppTheme.schemeFor(AppTheme.accentOf(context), brightness),
      scaffoldBackgroundColor: widget.paper.background,
    );
    return Theme(
      data: theme,
      child: Builder(builder: _buildSheet),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = widget.paper.foreground;
    return AppBottomSheet(
      title: widget.title,
      // 副标题是拉到的真实总数，首屏返回后会跟着修正。
      subtitle: '$_totalCount 条评论',
      // 0.76 屏高：一屏能看四五条评论，同时留出阅读页作为上下文。
      heightFactor: 0.76,
      backgroundColor: widget.paper.background,
      foregroundColor: foreground,
      closeTooltip: '关闭评论',
      child: _buildBody(scheme, foreground),
    );
  }

  Widget _buildBody(ColorScheme scheme, Color foreground) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_firstPageError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('评论加载失败', style: TextStyle(fontSize: 14, color: foreground)),
            TextButton(onPressed: _loadFirstPage, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return Center(
        child: Text(
          '还没有评论',
          style: TextStyle(
            fontSize: 14,
            color: foreground.withValues(alpha: 0.55),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: _comments.length + 1,
      itemBuilder: (context, index) {
        if (index == _comments.length) {
          return _buildFooter(scheme, foreground);
        }
        return _buildCommentTile(scheme, foreground, _comments[index]);
      },
    );
  }

  Widget _buildFooter(ColorScheme scheme, Color foreground) {
    final muted = foreground.withValues(alpha: 0.5);
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('加载中…', style: TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      );
    }
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: InkWell(
            onTap: _retryLoadMore,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '加载失败，点击重试',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('没有更多了', style: TextStyle(fontSize: 12, color: muted)),
        ),
      );
    }
    // 还有下一页但尚未触发：只留一点空白，等滚动到底再拉。
    return const SizedBox(height: 12);
  }

  Widget _buildCommentTile(
    ColorScheme scheme,
    Color foreground,
    BookComment comment,
  ) {
    final replies = _replies[_commentKey(comment)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 列表不加载网络头像：滚动时每张图都是一次请求，也没必要为了
              // 只读弹层引入图片缓存；用昵称首字占位，视觉上仍能区分用户。
              _buildInitialAvatar(comment.userName, scheme, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildNameRow(comment, scheme, foreground),
                    if (comment.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        comment.text,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: foreground,
                        ),
                      ),
                    ],
                    if (comment.imageUrls.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      CommentImageStrip(
                        imageRefs: comment.imageRefsOrFallback,
                        // 弹层底色跟随纸色，占位块不能直接吃全局主题的灰。
                        placeholderColor: foreground.withValues(alpha: 0.06),
                      ),
                    ],
                    const SizedBox(height: 6),
                    _buildMetaRow(comment, scheme, foreground),
                  ],
                ),
              ),
            ],
          ),
          if (replies != null && replies.expanded)
            _buildRepliesSection(scheme, foreground, comment, replies),
        ],
      ),
    );
  }

  Widget _buildNameRow(
    BookComment comment,
    ColorScheme scheme,
    Color foreground,
  ) {
    final name = comment.userName.trim().isEmpty
        ? '匿名读者'
        : comment.userName.trim();
    final time = comment.timeLabel();
    // 昵称、作者徽章、时间连在一起（和回复行一致）；不再用 Spacer 把时间
    // 顶到右边——一行里只隔一小段空白读起来更自然。
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            key: ValueKey('comment-name-${comment.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ),
        if (comment.isAuthor) ...[
          const SizedBox(width: 4),
          _buildAuthorBadge(scheme),
        ],
        if (time.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            time,
            key: ValueKey('comment-time-${comment.id}'),
            style: TextStyle(
              fontSize: 11,
              color: foreground.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAuthorBadge(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '作者',
        style: TextStyle(fontSize: 10, height: 1.2, color: scheme.primary),
      ),
    );
  }

  Widget _buildMetaRow(
    BookComment comment,
    ColorScheme scheme,
    Color foreground,
  ) {
    final muted = foreground.withValues(alpha: 0.5);
    final expanded = _replies[_commentKey(comment)]?.expanded ?? false;
    return Row(
      children: [
        // 点赞只读展示：本面板不提供写接口，不包 InkWell 以免误导用户可以点。
        Icon(Icons.thumb_up_alt_outlined, size: 13, color: muted),
        const SizedBox(width: 3),
        Text(
          '${comment.diggCount}',
          style: TextStyle(fontSize: 11, color: muted),
        ),
        if (comment.replyCount > 0) ...[
          const Spacer(),
          InkWell(
            onTap: () => _toggleReplies(comment),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                expanded ? '收起回复' : '${comment.replyCount} 条回复',
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRepliesSection(
    ColorScheme scheme,
    Color foreground,
    BookComment comment,
    _ReplyState state,
  ) {
    final muted = foreground.withValues(alpha: 0.55);
    final Widget content;
    if (state.loading) {
      content = Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('回复加载中…', style: TextStyle(fontSize: 12, color: muted)),
        ],
      );
    } else if (state.error != null) {
      content = InkWell(
        onTap: () => _retryReplies(comment, state),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '回复加载失败，点击重试',
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
        ),
      );
    } else if (state.replies.isEmpty) {
      content = Text('还没有回复', style: TextStyle(fontSize: 12, color: muted));
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final reply in state.replies)
            _buildReplyTile(scheme, foreground, reply),
        ],
      );
    }
    return Padding(
      // 缩进对齐评论正文（头像 34 + 间距 10），回复区不额外画分割线。
      padding: const EdgeInsets.only(left: 44, top: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: content,
      ),
    );
  }

  Widget _buildReplyTile(
    ColorScheme scheme,
    Color foreground,
    CommentReply reply,
  ) {
    final muted = foreground.withValues(alpha: 0.5);
    final name = reply.userName.trim().isEmpty ? '匿名读者' : reply.userName.trim();
    final time = _timeLabel(reply.createdAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInitialAvatar(reply.userName, scheme, radius: 11),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (time.isNotEmpty)
                      Text(time, style: TextStyle(fontSize: 10, color: muted)),
                  ],
                ),
                if (reply.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    reply.text,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: foreground,
                    ),
                  ),
                ],
                if (reply.imageUrls.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  CommentImageStrip(
                    imageRefs: reply.imageRefsOrFallback,
                    compact: true,
                    placeholderColor: foreground.withValues(alpha: 0.06),
                  ),
                ],
                if (reply.diggCount > 0) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(Icons.thumb_up_alt_outlined, size: 12, color: muted),
                      const SizedBox(width: 3),
                      Text(
                        '${reply.diggCount}',
                        style: TextStyle(fontSize: 10, color: muted),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitialAvatar(
    String userName,
    ColorScheme scheme, {
    required double radius,
  }) {
    final trimmed = userName.trim();
    // 用 runes 取首字：中文/emoji 才不会被截成半个代理对。
    final initial = trimmed.isEmpty
        ? '匿'
        : String.fromCharCode(trimmed.runes.first);
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primary.withValues(alpha: 0.12),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// [CommentReply] 没带 [BookComment.timeLabel]，但时间戳语义完全一致；这里
/// 复用同一套相对时间文案，避免回复和评论出现两种时间格式。
String _timeLabel(DateTime? createdAt) {
  if (createdAt == null) return '';
  final now = DateTime.now();
  final diff = now.difference(createdAt);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  final month = createdAt.month.toString().padLeft(2, '0');
  final day = createdAt.day.toString().padLeft(2, '0');
  return createdAt.year == now.year
      ? '$month-$day'
      : '${createdAt.year}-$month-$day';
}
