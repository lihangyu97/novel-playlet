import 'comment_image.dart';
import 'json_utils.dart';

/// 一条评论回复。
///
/// 上游把字段放在大写的 `Common` 里（`reply_list[].Common.content.text`），
/// 同时兼容小写；统计在 `stat`。
class CommentReply {
  const CommentReply({
    this.id = '',
    this.text = '',
    this.imageUrls = const <String>[],
    this.imageRefs = const <CommentImageRef>[],
    this.diggCount = 0,
    this.createdAt,
    this.userName = '',
    this.userAvatar = '',
  });

  final String id;
  final String text;

  /// 配图原图 URL（查看器/旧调用方用）；解析器同时填 [imageRefs]。
  final List<String> imageUrls;

  /// 配图缩略图 + 原图（UI 渲染优先用它）。
  final List<CommentImageRef> imageRefs;

  final int diggCount;
  final DateTime? createdAt;
  final String userName;
  final String userAvatar;

  /// 渲染用配图：优先新字段（含 thumb/full），只有旧字段时 thumb=full。
  List<CommentImageRef> get imageRefsOrFallback => imageRefs.isNotEmpty
      ? imageRefs
      : <CommentImageRef>[
          for (final url in imageUrls) CommentImageRef(thumb: url, full: url),
        ];

  bool get isEmpty =>
      text.trim().isEmpty && imageUrls.isEmpty && imageRefs.isEmpty;

  static CommentReply? fromPayload(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final common = asMap(map['Common']) ?? asMap(map['common']) ?? map;
    final content = asMap(common['content']) ?? const <String, dynamic>{};
    final stat = asMap(map['stat']) ?? const <String, dynamic>{};
    final userInfo = asMap(common['user_info']) ?? const <String, dynamic>{};
    final baseInfo =
        asMap(userInfo['base_info']) ?? asMap(userInfo['baseInfo']) ?? userInfo;
    final text = firstString(content, ['text', 'content']);
    final images = parseCommentImageRefs(
      content['image_data_list'] ?? content['image_data'],
    );
    if (text.isEmpty && images.isEmpty) return null;
    return CommentReply(
      id: firstString(map, ['reply_id', 'replyId', 'id']),
      text: text,
      imageUrls: <String>[for (final ref in images) ref.full],
      imageRefs: images,
      diggCount: asInt(stat['digg_count'] ?? stat['diggCount']),
      createdAt: _parseTime(
        common['create_timestamp'] ?? common['createTimestamp'],
      ),
      userName: firstString(baseInfo, ['user_name', 'userName', 'name']),
      userAvatar: firstString(baseInfo, ['user_avatar', 'userAvatar']),
    );
  }
}

/// 一页回复。
class CommentReplyPage {
  const CommentReplyPage({
    this.replies = const <CommentReply>[],
    this.totalCount = 0,
    this.cursor = '',
    this.hasMore = false,
  });

  static const empty = CommentReplyPage();

  final List<CommentReply> replies;
  final int totalCount;
  final String cursor;
  final bool hasMore;

  bool get isEmpty => replies.isEmpty;

  /// 解析 `POST /novel/commentapi/reply/list/{comment_id}/v1/`。
  static CommentReplyPage fromPayload(Map<String, dynamic> payload) {
    final code = asInt(payload['code'], -1);
    if (code == 103001 || code == 1301008) return empty;
    final data = unwrapEnvelope(payload);
    final replies = <CommentReply>[];
    for (final entry in asList(data['reply_list'])) {
      final reply = CommentReply.fromPayload(entry);
      if (reply != null) replies.add(reply);
    }
    final info =
        asMap(data['common_list_info']) ??
        asMap(data['comment_list_info']) ??
        const <String, dynamic>{};
    return CommentReplyPage(
      replies: List<CommentReply>.unmodifiable(replies),
      totalCount: asInt(info['total'], replies.length),
      cursor: asString(info['cursor']),
      hasMore: info['has_more'] == true,
    );
  }
}

DateTime? _parseTime(Object? raw) {
  final value = asInt(raw);
  if (value <= 0) return null;
  final ms = value > 100000000000 ? value : value * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
