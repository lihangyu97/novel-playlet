import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/models/book_comment.dart';
import '../../data/models/comment_reply.dart';
import '../providers.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';
import 'comment_emoji_text.dart';
import 'comment_image_strip.dart';
import 'states.dart';

/// 评论列表的数据源。
///
/// 书评、剧评、本集评论、阅读页段评/章评的 UI 和分页状态完全共用，只有
/// 「怎么取下一页、要不要画星级、有没有回复、用什么配色」不同：
/// - 书评是 legacy offset 分页；
/// - 短剧/段评是 `common_list_info.cursor` 游标分页；
/// - 只有阅读页段评有回复懒加载，且弹层跟随阅读器纸色。
///
/// [cursor] 对调用方是不透明字符串：首页传空串，后续原样回传
/// [nextCursor] 的返回值；实现自己决定它代表 offset 还是游标。
abstract class CommentFeed {
  const CommentFeed();

  String get title;

  String get emptyMessage;

  String get errorMessage;

  String get closeTooltip;

  /// 上游可能返回 `total>0` 但列表为空的「风控空成功」；目前只有短剧需要重试。
  bool get retryEmptyFirstPage => false;

  /// 只有阅读页段评提供；返回 null 时列表不显示「N 条回复」入口。
  CommentReplyLoader? get replyLoader => null;

  int get replyPageSize => 10;

  /// 书评在昵称后面画星级；短剧/段评返回 null。
  Widget? buildScore(BookComment comment) => null;

  Future<BookCommentPage> load(String cursor);

  /// 一页之后的下一页 token；返回空串表示没有下一页。
  ///
  /// [previousCursor] 是本次请求用的 token，用来判断服务端有没有推进游标。
  String nextCursor(BookCommentPage page, String previousCursor);
}

typedef CommentFeedBuilder = CommentFeed Function(ApiClient api);

typedef CommentReplyLoader = Future<CommentReplyPage> Function(
  BookComment comment,
);

/// 评论弹层的配色/主题覆盖。
///
/// 阅读页段评/章评要跟随阅读器纸色，连 Material 主题一起换（强调色、分割线、
/// 按钮文字都按纸色明暗重建）；详情页/短剧评论不传，直接跟随 App 当前主题。
class CommentSheetStyle {
  const CommentSheetStyle({
    this.theme,
    this.backgroundColor,
    this.foregroundColor,
  });

  final ThemeData? theme;
  final Color? backgroundColor;
  final Color? foregroundColor;
}

/// 所有评论列表共用的弹层。
class CommentListSheet extends ConsumerStatefulWidget {
  const CommentListSheet({
    super.key,
    required this.feedBuilder,
    this.initialPage,
    this.initialTotal = 0,
    this.style,
  });

  final CommentFeedBuilder feedBuilder;

  /// 详情页已经拿到的第一页；非空时直接铺列表，不再请求首屏。
  final BookCommentPage? initialPage;

  /// 详情页/阅读页已知的总数（首屏返回前先显示）。
  final int initialTotal;

  /// 阅读页纸色主题；null = 跟随 App 主题。
  final CommentSheetStyle? style;

  @override
  ConsumerState<CommentListSheet> createState() => _CommentListSheetState();
}

class _CommentListSheetState extends ConsumerState<CommentListSheet> {
  static const int _loadMoreThreshold = 300;

  final ScrollController _scrollController = ScrollController();
  final List<BookComment> _comments = <BookComment>[];
  final Map<String, _ReplyState> _replies = <String, _ReplyState>{};

  late final CommentFeed _feed;

  int _totalCount = 0;
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _emptyRetried = false;
  String? _loadMoreError;

  @override
  void initState() {
    super.initState();
    _feed = widget.feedBuilder(ref.read(apiClientProvider));
    _totalCount = widget.initialTotal;
    _scrollController.addListener(_handleScroll);
    final initial = widget.initialPage;
    if (initial != null && initial.comments.isNotEmpty) {
      _loading = false;
      _adopt(initial);
    } else {
      unawaited(_loadFirstPage());
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _adopt(BookCommentPage page) {
    _comments
      ..clear()
      ..addAll(page.comments);
    // 首屏/详情页带来的总数优先；上游翻页页的 total 常为 0。
    if (page.totalCount > 0) {
      _totalCount = page.totalCount;
    } else if (_totalCount == 0) {
      _totalCount = page.comments.length;
    }
    _cursor = _feed.nextCursor(page, '');
    _hasMore = page.hasMore;
    _loadMoreError = null;
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreError = null;
    });
    try {
      final page = await _feed.load('');
      if (!mounted) return;
      // 上游 comment/list 可能返回 code=0、total>0、data_list=[] 的风控
      // 空成功；直接展示会变成「共 N 条 + 还没有评论」。自动重试一次仍为空
      // 才报可重试错误，避免把限流伪装成没有评论。
      if (_feed.retryEmptyFirstPage &&
          page.comments.isEmpty &&
          page.totalCount > 0) {
        if (!_emptyRetried) {
          _emptyRetried = true;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (!mounted) return;
          await _loadFirstPage();
          return;
        }
        setState(() {
          _loading = false;
          _error = _feed.errorMessage;
        });
        return;
      }
      _emptyRetried = false;
      setState(() {
        _loading = false;
        _error = null;
        _adopt(page);
      });
      _scheduleAutoFill();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _feed.errorMessage;
      });
    }
  }

  void _retryFirstPage() {
    setState(() {
      _loading = true;
      _error = null;
      _emptyRetried = false;
    });
    unawaited(_loadFirstPage());
  }

  void _handleScroll() {
    if (!_hasMore || _loadingMore || _loadMoreError != null) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter > _loadMoreThreshold) return;
    unawaited(_loadMore());
  }

  /// 首屏不足一屏时不会有滚动事件；主动补一页，否则用户会以为没有更多。
  void _scheduleAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || _loadingMore) return;
      if (!_hasMore || _loadMoreError != null) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter > _loadMoreThreshold) return;
      unawaited(_loadMore());
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    if (_loadMoreError != null) return;
    final previousCursor = _cursor;
    setState(() => _loadingMore = true);
    try {
      final page = await _feed.load(previousCursor);
      if (!mounted) return;
      final before = _comments.length;
      final seen = <String>{
        for (final comment in _comments)
          if (comment.id.isNotEmpty) comment.id,
      };
      for (final comment in page.comments) {
        if (comment.id.isNotEmpty && !seen.add(comment.id)) continue;
        _comments.add(comment);
      }
      final added = _comments.length - before;
      final nextCursor = _feed.nextCursor(page, previousCursor);
      final advanced = nextCursor.isNotEmpty && nextCursor != previousCursor;
      setState(() {
        _loadingMore = false;
        if (page.totalCount > 0) _totalCount = page.totalCount;
        _cursor = nextCursor;
        _hasMore = page.hasMore && advanced && added > 0;
      });
      _scheduleAutoFill();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = _feed.errorMessage;
      });
    }
  }

  void _retryLoadMore() {
    setState(() => _loadMoreError = null);
    unawaited(_loadMore());
  }

  String _commentKey(BookComment comment) => comment.id.isNotEmpty
      ? comment.id
      : 'object-${identityHashCode(comment)}';

  void _toggleReplies(BookComment comment) {
    final loader = _feed.replyLoader;
    if (loader == null) return;
    final key = _commentKey(comment);
    final state = _replies.putIfAbsent(key, () => _ReplyState());
    if (state.expanded) {
      setState(() => state.expanded = false);
      return;
    }
    setState(() => state.expanded = true);
    if (!state.loaded && !state.loading) _loadReplies(comment, state, loader);
  }

  Future<void> _loadReplies(
    BookComment comment,
    _ReplyState state,
    CommentReplyLoader loader,
  ) async {
    setState(() {
      state.loading = true;
      state.error = null;
    });
    try {
      final page = await loader(comment);
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.loaded = true;
        state.replies = page.replies;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.error = true;
      });
    }
  }

  void _retryReplies(BookComment comment, _ReplyState state) {
    final loader = _feed.replyLoader;
    if (loader == null || state.loading) return;
    _loadReplies(comment, state, loader);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.style?.theme ?? Theme.of(context);
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          final foreground = widget.style?.foregroundColor ?? scheme.onSurface;
          final background = widget.style?.backgroundColor ?? scheme.surface;
          return AppBottomSheet(
            title: _feed.title,
            subtitle: '$_totalCount 条评论',
            heightFactor: 0.8,
            backgroundColor: background,
            foregroundColor: foreground,
            closeTooltip: _feed.closeTooltip,
            child: _buildBody(scheme, foreground),
          );
        },
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme, Color foreground) {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(fontSize: 14, color: foreground)),
            TextButton(onPressed: _retryFirstPage, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return Center(
        child: Text(
          _feed.emptyMessage,
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
        final comment = _comments[index];
        final replyState = _replies[_commentKey(comment)];
        return _CommentTile(
          comment: comment,
          scheme: scheme,
          foreground: foreground,
          score: _feed.buildScore(comment),
          onToggleReplies: _feed.replyLoader == null
              ? null
              : () => _toggleReplies(comment),
          repliesExpanded: replyState?.expanded ?? false,
          replies: replyState != null && replyState.expanded
              ? _buildRepliesSection(scheme, foreground, comment, replyState)
              : null,
        );
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
    return const SizedBox(height: 12);
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
      // 缩进对齐评论正文（头像 34 + 间距 10）。
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
          _InitialAvatar(name: reply.userName, scheme: scheme, radius: 11),
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
                          fontWeight: context.appWeight(FontWeight.w500),
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
                  CommentEmojiText(
                    text: reply.text,
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
}

/// 一条评论的回复区状态：展开/收起 + 懒加载结果。
class _ReplyState {
  bool expanded = false;
  bool loading = false;
  bool loaded = false;
  bool? error;
  List<CommentReply> replies = const <CommentReply>[];
}

/// 评论行：四套评论列表共用同一套排版，特殊项（星级）由 Feed 注入。
class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.scheme,
    required this.foreground,
    required this.score,
    required this.onToggleReplies,
    required this.repliesExpanded,
    required this.replies,
  });

  final BookComment comment;
  final ColorScheme scheme;
  final Color foreground;
  final Widget? score;
  final VoidCallback? onToggleReplies;
  final bool repliesExpanded;
  final Widget? replies;

  @override
  Widget build(BuildContext context) {
    final name = comment.userName.trim().isEmpty
        ? '匿名读者'
        : comment.userName.trim();
    final text = comment.text.trim();
    final time = comment.timeLabel();
    final muted = foreground.withValues(alpha: 0.5);
    final metaStyle = TextStyle(fontSize: 11, color: muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InitialAvatar(name: name, scheme: scheme, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            key: ValueKey('comment-name-${comment.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: context.appWeight(FontWeight.w600),
                              color: foreground,
                            ),
                          ),
                        ),
                        if (comment.isAuthor) ...[
                          const SizedBox(width: 4),
                          _AuthorBadge(scheme: scheme),
                        ],
                        if (score != null) ...[
                          const SizedBox(width: 6),
                          score!,
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
                    ),
                    if (text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      CommentEmojiText(
                        text: comment.text,
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
                        placeholderColor: foreground.withValues(alpha: 0.06),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.thumb_up_alt_outlined,
                          size: 13,
                          color: muted,
                        ),
                        const SizedBox(width: 3),
                        Text('${comment.diggCount}', style: metaStyle),
                        if (onToggleReplies != null &&
                            comment.replyCount > 0) ...[
                          const Spacer(),
                          InkWell(
                            onTap: onToggleReplies,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                repliesExpanded
                                    ? '收起回复'
                                    : '${comment.replyCount} 条回复',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ?replies,
        ],
      ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({
    required this.name,
    required this.scheme,
    required this.radius,
  });

  final String name;
  final ColorScheme scheme;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
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
          fontWeight: context.appWeight(FontWeight.w600),
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _AuthorBadge extends StatelessWidget {
  const _AuthorBadge({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
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
}

/// [CommentReply] 没带 `BookComment.timeLabel`，但时间戳语义完全一致。
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
