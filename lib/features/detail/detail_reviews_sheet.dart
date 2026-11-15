import 'package:flutter/material.dart';

import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/comment_list_sheet.dart';
import '../../data/api/api_client.dart';
import '../../data/models/book_comment.dart';
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

/// 全部书评弹层：数据源是 legacy offset 分页，UI 与短剧评论共用。
class DetailReviewsSheet extends StatelessWidget {
  const DetailReviewsSheet({super.key, required this.bookId, this.initialPage});

  final String bookId;
  final BookCommentPage? initialPage;

  @override
  Widget build(BuildContext context) {
    return CommentListSheet(
      feedBuilder: (api) => _BookReviewsFeed(api: api, bookId: bookId),
      initialPage: initialPage,
    );
  }
}

/// 小说书评的接口差异都收在这里：legacy `/books/{id}/comments` + offset 分页。
class _BookReviewsFeed extends CommentFeed {
  const _BookReviewsFeed({required this.api, required this.bookId});

  final ApiClient api;
  final String bookId;

  @override
  String get title => '书评';

  @override
  String get emptyMessage => '还没有书评';

  @override
  String get errorMessage => '书评加载失败，请重试';

  @override
  String get closeTooltip => '关闭书评';

  @override
  Widget? buildScore(BookComment comment) =>
      DetailReviewStars(stars: comment.stars);

  @override
  Future<BookCommentPage> load(String cursor) {
    final offset = int.tryParse(cursor) ?? 0;
    return api.bookComments(bookId, count: bookReviewsPageSize, offset: offset);
  }

  @override
  String nextCursor(BookCommentPage page, String previousCursor) {
    final previous = int.tryParse(previousCursor) ?? 0;
    if (page.nextOffset > previous) return '${page.nextOffset}';
    // 老接口偶尔不推进 next_offset；只要本页有内容就按本页条数前进，
    // 由共享层再用 added>0 / hasMore 兜住循环。
    final fallback = previous + page.comments.length;
    return fallback > previous ? '$fallback' : '';
  }
}
