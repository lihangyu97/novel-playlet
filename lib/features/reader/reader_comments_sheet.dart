import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/comment_list_sheet.dart';
import '../../data/api/api_client.dart';
import '../../data/models/book_comment.dart';

/// 打开阅读页的评论面板（只读）。
///
/// 段评和章末评论共用这一套：调用方只给「哪本书/哪一章/哪一段」这组定位参数，
/// 首屏、翻页、回复懒加载都在共用列表壳内完成。面板不写任何接口——点赞、回复
/// 都只展示，避免阅读页为了一个弹层持有写操作状态。
///
/// [paper] 决定弹层底色和文字色（夜间/护眼纸色下弹层不能还是白底）。
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

/// 阅读页评论面板：列表 UI/分页/回复都走共用内核，只有纸色主题和段评接口不同。
class ReaderCommentsSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    // 弹层挂 root Navigator，拿不到阅读页内部的局部主题；这里按纸色明暗和
    // 全局主题色重建一套，保证夜间模式/强调色下的对比度与阅读页一致。
    final brightness = paper == ReaderPaper.night
        ? Brightness.dark
        : Brightness.light;
    final theme = Theme.of(context).copyWith(
      colorScheme: AppTheme.schemeFor(AppTheme.accentOf(context), brightness),
      scaffoldBackgroundColor: paper.background,
    );
    return CommentListSheet(
      feedBuilder: (api) => _ReaderParagraphFeed(
        api: api,
        bookId: bookId,
        chapterId: chapterId,
        itemVersion: itemVersion,
        paraIndex: paraIndex,
        sheetTitle: title,
      ),
      initialTotal: totalCount,
      style: CommentSheetStyle(
        theme: theme,
        backgroundColor: paper.background,
        foregroundColor: paper.foreground,
      ),
    );
  }
}

/// 阅读页段评/章评的数据源：`paragraphComments` + cursor 分页 + 回复懒加载。
class _ReaderParagraphFeed extends CommentFeed {
  const _ReaderParagraphFeed({
    required this.api,
    required this.bookId,
    required this.chapterId,
    required this.itemVersion,
    required this.paraIndex,
    required this.sheetTitle,
  });

  static const int _pageSize = 20;

  final ApiClient api;
  final String bookId;
  final String chapterId;
  final String itemVersion;
  final int paraIndex;
  final String sheetTitle;

  @override
  String get title => sheetTitle;

  @override
  String get emptyMessage => '还没有评论';

  @override
  String get errorMessage => '评论加载失败';

  @override
  String get closeTooltip => '关闭评论';

  @override
  int get replyPageSize => 10;

  @override
  CommentReplyLoader get replyLoader =>
      (comment) => api.commentReplies(
        comment.id,
        bookId: bookId,
        // 段评回复按「章节」归组，group_id 就是章节 itemId。
        groupId: chapterId,
        count: replyPageSize,
      );

  @override
  Future<BookCommentPage> load(String cursor) {
    return api.paragraphComments(
      bookId,
      chapterId,
      paraIndex: paraIndex,
      itemVersion: itemVersion,
      count: _pageSize,
      cursor: cursor,
    );
  }

  @override
  String nextCursor(BookCommentPage page, String previousCursor) => page.cursor;
}
