import 'package:flutter/material.dart';

import '../../../app/widgets/app_bottom_sheet.dart';
import '../../../app/widgets/comment_list_sheet.dart';
import '../../../data/api/api_client.dart';
import '../../../data/models/book_comment.dart';
import '../video_comments_providers.dart';

/// 打开短剧评论弹层。
///
/// [vid] 为空 = 整部剧的「剧评」（cursor 翻页）；非空 = 当前这一集的评论
/// （也按 `common_list_info.cursor` 翻页，每页 20 条）。
///
/// [initialPage] 是详情页已经拿到的第一页：有它就先铺列表，避免打开弹层
/// 时先闪一下 loading。
Future<void> showVideoCommentsSheet(
  BuildContext context, {
  required String seriesId,
  String vid = '',
  BookCommentPage? initialPage,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (_) => VideoCommentsSheet(
      seriesId: seriesId,
      vid: vid,
      initialPage: initialPage,
    ),
  );
}

/// 短剧评论弹层：剧评 / 本集评论只差数据源，列表 UI 与书评共用。
class VideoCommentsSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return CommentListSheet(
      feedBuilder: (api) =>
          _VideoCommentsFeed(api: api, seriesId: seriesId, vid: vid),
      initialPage: initialPage,
    );
  }
}

/// 短剧评论的接口差异都收在这里：剧评 / 本集评论都走 comment/list + cursor。
class _VideoCommentsFeed extends CommentFeed {
  const _VideoCommentsFeed({
    required this.api,
    required this.seriesId,
    required this.vid,
  });

  final ApiClient api;
  final String seriesId;
  final String vid;

  bool get _isEpisode => vid.isNotEmpty;

  @override
  String get title => _isEpisode ? '本集评论' : '剧评';

  @override
  String get emptyMessage => _isEpisode ? '本集还没有评论' : '还没有剧评';

  @override
  String get errorMessage => _isEpisode ? '本集评论加载失败，请重试' : '剧评加载失败，请重试';

  @override
  String get closeTooltip => '关闭评论';

  @override
  bool get retryEmptyFirstPage => true;

  @override
  Future<BookCommentPage> load(String cursor) {
    if (_isEpisode) {
      return api.episodeComments(seriesId, vid, cursor: cursor);
    }
    return api.seriesComments(
      seriesId,
      count: videoCommentsPageSize,
      cursor: cursor,
    );
  }

  @override
  String nextCursor(BookCommentPage page, String previousCursor) => page.cursor;
}
