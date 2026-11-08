import 'json_utils.dart';

/// 段评气泡样式：普通 / 有读者评论（勾选）/ 作者本人评论（笔尖）。
///
/// 官方按 `user_count` 和 `is_author_comment` 选皮肤；我们自绘时只需要区分
/// 颜色/图标，语义保持一致即可。
enum ParagraphBubbleVariant { plain, users, author }

/// 一段的段评汇总（只有计数和评论 id，正文要第二跳）。
class ParagraphIdeas {
  const ParagraphIdeas({
    required this.paraIndex,
    this.count = 0,
    this.commentIds = const <String>[],
    this.channelCounts = const <int, int>{},
    this.userCount = 0,
    this.isAuthor = false,
  });

  /// 上游段落 id，来自正文 HTML 的 `<p idx="N">`。
  final int paraIndex;

  final int count;

  /// 该段的评论 id（`infos[].comment_id`），正文按需再拉。
  final List<String> commentIds;

  /// 各展示渠道的计数（`bubble_data`），本 App 只展示总 count。
  final Map<int, int> channelCounts;

  final int userCount;
  final bool isAuthor;

  bool get hasIdeas => count > 0;

  ParagraphBubbleVariant get bubbleVariant => isAuthor
      ? ParagraphBubbleVariant.author
      : userCount > 0
      ? ParagraphBubbleVariant.users
      : ParagraphBubbleVariant.plain;

  /// 气泡上显示的短计数：>99 截断，和官方一致。
  String get bubbleLabel => count > 99 ? '99+' : '$count';
}

/// 一章的段评汇总。
class ChapterIdeas {
  const ChapterIdeas({
    this.itemVersion = '',
    this.paragraphs = const <ParagraphIdeas>[],
  });

  static const empty = ChapterIdeas();

  /// 上游回显的正文版本，可用于评论列表的 `item_version` 回退。
  final String itemVersion;

  final List<ParagraphIdeas> paragraphs;

  bool get isEmpty => paragraphs.isEmpty;
  bool get isNotEmpty => paragraphs.isNotEmpty;

  List<ParagraphIdeas> get withIdeas => [
    for (final paragraph in paragraphs)
      if (paragraph.hasIdeas) paragraph,
  ];

  /// 段号 → 气泡计数，只包含真正要画气泡的段。
  Map<int, int> get bubbleCounts => {
    for (final paragraph in paragraphs)
      if (paragraph.hasIdeas) paragraph.paraIndex: paragraph.count,
  };

  Map<int, ParagraphBubbleVariant> get bubbleVariants => {
    for (final paragraph in paragraphs)
      if (paragraph.hasIdeas) paragraph.paraIndex: paragraph.bubbleVariant,
  };

  /// 全章段评总数（章末「本章评论 N」用）。
  int get total {
    var sum = 0;
    for (final paragraph in paragraphs) {
      sum += paragraph.count;
    }
    return sum;
  }

  ParagraphIdeas? forParagraph(int paraIndex) {
    for (final paragraph in paragraphs) {
      if (paragraph.paraIndex == paraIndex) return paragraph;
    }
    return null;
  }

  /// 章末聚合桶：段号最大的那个桶（官方约定 10000+）。
  ///
  /// 不是「评论最多的段」；真实 payload 里它通常排在最后。
  int? get chapterEndParaIndex =>
      paragraphs.isEmpty ? null : paragraphs.last.paraIndex;

  /// 业务码 103001/1301008 表示「这本书/这章没有段评」，不是失败。
  static bool isUnavailableCode(Object? code) {
    final value = asInt(code, -1);
    return value == 103001 || value == 1301008;
  }

  /// 解析 `POST /novel/commentapi/idea/list/{item_id}/v1/`。
  ///
  /// `data.data` 是按段落 id 分桶的 map；段评是阅读页装饰，解析失败一律当空。
  static ChapterIdeas fromPayload(Map<String, dynamic> payload) {
    if (isUnavailableCode(payload['code'])) return empty;
    Map<String, dynamic> data;
    try {
      data = unwrapEnvelope(payload);
    } catch (_) {
      return empty;
    }
    final buckets = asMap(data['data']);
    if (buckets == null) return empty;
    final paragraphs = <ParagraphIdeas>[];
    for (final entry in buckets.entries) {
      final paraIndex = int.tryParse(entry.key.trim());
      final map = asMap(entry.value);
      if (paraIndex == null || map == null) continue;
      final infos = asList(map['infos']);
      final commentIds = <String>[];
      for (final info in infos) {
        final id = firstString(asMap(info) ?? const {}, ['comment_id']);
        if (id.isNotEmpty) commentIds.add(id);
      }
      final channelCounts = <int, int>{};
      final bubbleData = asMap(map['bubble_data']);
      if (bubbleData != null) {
        for (final entry in bubbleData.entries) {
          final channel = int.tryParse(entry.key.trim());
          if (channel == null) continue;
          channelCounts[channel] = asInt(asMap(entry.value)?['count']);
        }
      }
      paragraphs.add(
        ParagraphIdeas(
          paraIndex: paraIndex,
          count: asInt(map['count']),
          commentIds: List<String>.unmodifiable(commentIds),
          channelCounts: Map<int, int>.unmodifiable(channelCounts),
          userCount: asInt(map['user_count']),
          isAuthor: map['is_author_comment'] == true,
        ),
      );
    }
    paragraphs.sort((a, b) => a.paraIndex.compareTo(b.paraIndex));
    return ChapterIdeas(
      itemVersion: firstString(data, ['item_version']),
      paragraphs: List<ParagraphIdeas>.unmodifiable(paragraphs),
    );
  }
}
