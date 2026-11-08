import 'comment_image.dart';
import 'json_utils.dart';

/// 一条评论（段评 / 章末评论 / 书评共用）。
///
/// 上游把正文放在 `comment.common.content.text`，计数在 `comment.stat`
/// （外层也可能有一份 `stat`），段评正文走 `data_list[]`，旧书评走
/// `data.comment[]`——两种形状都在这里归一成同一份模型。
class BookComment {
  const BookComment({
    this.id = '',
    this.text = '',
    this.imageUrls = const <String>[],
    this.score = 0,
    this.diggCount = 0,
    this.replyCount = 0,
    this.readSeconds = 0,
    this.createdAt,
    this.userName = '',
    this.userAvatar = '',
    this.isAuthor = false,
    this.dataType = 0,
  });

  final String id;
  final String text;
  final List<String> imageUrls;

  /// 书评才有：上游 0–10 分；段评恒为 0。
  final int score;

  final int diggCount;
  final int replyCount;

  /// 书评才有：评论者已读时长（秒）。
  final int readSeconds;

  final DateTime? createdAt;
  final String userName;
  final String userAvatar;
  final bool isAuthor;

  /// `data_type`：段评/书评 0，短剧评论另有一套取值（本模型不区分）。
  final int dataType;

  bool get isEmpty => text.trim().isEmpty && imageUrls.isEmpty;

  /// 书评的 5 星展示（0–10 分折半）。
  double get stars => (score.clamp(0, 10)) / 2;

  /// 列表里的时间文案：一天内用相对时间，更早给日期。
  String timeLabel({DateTime? now}) {
    final created = createdAt;
    if (created == null) return '';
    final reference = now ?? DateTime.now();
    final diff = reference.difference(created);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    final month = created.month.toString().padLeft(2, '0');
    final day = created.day.toString().padLeft(2, '0');
    return created.year == reference.year
        ? '$month-$day'
        : '${created.year}-$month-$day';
  }

  /// 解析 `data_list[]` 里的一条（`{comment: {...}, stat: {...}}`）。
  static BookComment? fromCommentListEntry(Object? raw) {
    final entry = asMap(raw);
    if (entry == null) return null;
    final comment = asMap(entry['comment']) ?? entry;
    final common = asMap(comment['common']) ?? comment;
    final content = asMap(common['content']) ?? const <String, dynamic>{};
    final stat = asMap(comment['stat']) ?? asMap(entry['stat']) ?? const {};
    final userInfo = asMap(common['user_info']) ?? const <String, dynamic>{};
    final baseInfo =
        asMap(userInfo['base_info']) ?? asMap(userInfo['baseInfo']) ?? const {};
    final userTag = asMap(userInfo['user_tag']) ?? const <String, dynamic>{};
    final text = firstString(content, ['text', 'content']);
    final images = parseCommentImages(
      content['image_data_list'] ?? content['image_data'],
    );
    if (text.isEmpty && images.isEmpty) return null;
    return BookComment(
      id: firstString(comment, ['comment_id', 'commentId', 'id']),
      text: text,
      imageUrls: images,
      diggCount: asInt(stat['digg_count'] ?? stat['diggCount']),
      replyCount: asInt(stat['reply_count'] ?? stat['replyCount']),
      createdAt: _parseTime(
        common['create_timestamp'] ?? common['createTimestamp'],
      ),
      userName: firstString(baseInfo, ['user_name', 'userName', 'name']),
      userAvatar: firstString(baseInfo, ['user_avatar', 'userAvatar']),
      isAuthor: userTag['is_author'] == true || userInfo['is_author'] == true,
      dataType: asInt(entry['data_type']),
    );
  }

  /// 解析旧书评 `data.comment[]` 的一条（字段是平铺的）。
  static BookComment? fromLegacyEntry(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final text = firstString(map, ['text', 'content']);
    final images = parseCommentImages(map['image_data_list'] ?? map['images']);
    if (text.isEmpty && images.isEmpty) return null;
    final userInfo = asMap(map['user_info']) ?? const <String, dynamic>{};
    final baseInfo =
        asMap(userInfo['base_info']) ?? asMap(userInfo['baseInfo']) ?? userInfo;
    return BookComment(
      id: firstString(map, ['comment_id', 'commentId', 'id']),
      text: text,
      imageUrls: images,
      score: asInt(map['score']),
      diggCount: asInt(map['digg_count'] ?? map['diggCount']),
      replyCount: asInt(map['reply_count'] ?? map['replyCount']),
      readSeconds: asInt(map['read_duration'] ?? map['readDuration']),
      createdAt: _parseTime(map['create_timestamp'] ?? map['createTimestamp']),
      userName: firstString(baseInfo, ['user_name', 'userName', 'name']),
      userAvatar: firstString(baseInfo, ['user_avatar', 'userAvatar']),
      isAuthor: userInfo['is_author'] == true,
    );
  }
}

/// 一页评论。
class BookCommentPage {
  const BookCommentPage({
    this.comments = const <BookComment>[],
    this.totalCount = 0,
    this.cursor = '',
    this.hasMore = false,
    this.nextOffset = 0,
    this.context = '',
  });

  static const empty = BookCommentPage();

  final List<BookComment> comments;

  /// 该段/该书的评论总数（段评取 `common_list_info.total`，书评取
  /// `comment_cnt`）。
  final int totalCount;

  /// 段评分页游标（原样回传）。
  final String cursor;
  final bool hasMore;

  /// 旧书评的 offset 分页。
  final int nextOffset;

  /// 书评页的现成文案，如「2.6万人点评」。
  final String context;

  bool get isEmpty => comments.isEmpty;

  /// 段评/短剧评论：`data_list[]` + `common_list_info`。
  ///
  /// 业务码 1301008 表示「内容不可用」，按空页处理而不是报错。
  static BookCommentPage fromCommentListPayload(Map<String, dynamic> payload) {
    if (_isUnavailableCode(payload['code'])) return empty;
    final Map<String, dynamic> data;
    try {
      data = unwrapEnvelope(payload);
    } catch (_) {
      rethrow;
    }
    final list = asList(data['data_list']);
    final comments = <BookComment>[];
    for (final entry in list) {
      final comment = BookComment.fromCommentListEntry(entry);
      if (comment != null) comments.add(comment);
    }
    final info =
        asMap(data['common_list_info']) ??
        asMap(data['comment_list_info']) ??
        const <String, dynamic>{};
    return BookCommentPage(
      comments: List<BookComment>.unmodifiable(comments),
      totalCount: asInt(info['total'], comments.length),
      cursor: asString(info['cursor']),
      hasMore: info['has_more'] == true,
    );
  }

  /// 旧书评：`data.comment[]` + `comment_cnt` / `score_cnt` / `context`。
  static BookCommentPage fromLegacyPayload(Map<String, dynamic> payload) {
    if (_isUnavailableCode(payload['code'])) return empty;
    final data = unwrapEnvelope(payload);
    final comments = <BookComment>[];
    for (final entry in asList(data['comment'])) {
      final comment = BookComment.fromLegacyEntry(entry);
      if (comment != null) comments.add(comment);
    }
    return BookCommentPage(
      comments: List<BookComment>.unmodifiable(comments),
      totalCount: asInt(data['comment_cnt'], comments.length),
      hasMore: data['has_more'] == true,
      nextOffset: asInt(data['next_offset'], comments.length),
      context: firstString(data, ['context']),
    );
  }
}

bool _isUnavailableCode(Object? code) {
  final value = asInt(code, -1);
  return value == 103001 || value == 1301008;
}

/// 上游时间戳有秒和毫秒两种；大于 1e11 当毫秒。
DateTime? _parseTime(Object? raw) {
  final value = asInt(raw);
  if (value <= 0) return null;
  final ms = value > 100000000000 ? value : value * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
