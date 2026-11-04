import 'json_utils.dart';

/// 小说详情（`/api/v1/books/{id}/detail`）。上游是 200 字段的 `BookInfo`，
/// 数值字段全是字符串，这里只取界面需要的。
class BookDetail {
  const BookDetail({
    this.bookId = '',
    this.title = '',
    this.cover = '',
    this.author = '',
    this.abstract = '',
    this.category = '',
    this.creationStatus = -1,
    this.wordNumber = 0,
    this.serialCount = 0,
    this.readCount = '',
    this.score = '',
    this.tags = const [],
    this.lastChapterTitle = '',
    this.rankTitle = '',
  });

  final String bookId;
  final String title;
  final String cover;
  final String author;
  final String abstract;
  final String category;

  /// 0 = 连载中，1 = 已完结（上游 `creation_status`）。-1 表示未知。
  final int creationStatus;
  final int wordNumber;
  final int serialCount;
  final String readCount;
  final String score;
  final List<String> tags;
  final String lastChapterTitle;
  final String rankTitle;

  String get statusLabel => switch (creationStatus) {
    0 => '连载中',
    1 => '已完结',
    _ => '',
  };

  String get wordLabel {
    if (wordNumber <= 0) return '';
    if (wordNumber < 10000) return '$wordNumber字';
    if (wordNumber >= 100000000) {
      return '${(wordNumber / 100000000).toStringAsFixed(1)}亿字';
    }
    // 与官方一致：1328318 -> 132.8万字。
    return '${(wordNumber / 10000).toStringAsFixed(1)}万字';
  }

  /// 分类 · 状态 · 字数，详情页信息行。
  /// 在读人数：上游给的是裸数字（1660045），展示时换算成"166.0万人在读"。
  String get readLabel {
    final count = int.tryParse(readCount.trim());
    if (count == null) return readCount;
    if (count < 10000) return '$count人在读';
    return '${(count / 10000).toStringAsFixed(1)}万人在读';
  }

  List<String> get metaParts => [
    if (category.isNotEmpty) category,
    if (statusLabel.isNotEmpty) statusLabel,
    if (wordLabel.isNotEmpty) wordLabel,
  ];

  factory BookDetail.fromPayload(Map<String, dynamic> payload) {
    final data = unwrapEnvelope(payload);
    // 上游 `tags` 实测是逗号串（"传统玄幻,玄幻,武侠,女帝,…"），不是数组；
    // 以前整串塞进一个 chip，详情页看起来像一行逗号文本。这里统一拆成独立
    // 标签，并兼容数组、中文逗号/顿号/斜杠分隔。
    final tags = <String>[];
    for (final entry in asList(data['tags'])) {
      for (final piece in asString(entry).split(RegExp(r'[,，、/|]'))) {
        final tag = piece.trim();
        if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
      }
    }
    final authorInfo = asMap(data['author_info']);
    // 上游 author_info 里显示名是 user_name（不是 name）。
    final author = firstString(authorInfo ?? const {}, ['user_name', 'name']);
    final category = firstString(data, ['category']);
    return BookDetail(
      bookId: firstString(data, ['book_id', 'item_id']),
      title: firstString(data, ['book_name', 'title', 'name']),
      // 封面只取缩略图：Hero 位只有 96×132，再大的图纯属浪费流量。字段顺序
      // 与 [NovelItem] 共用 [coverKeys]，两处拿到的通常是同一个 URL，从列表
      // 进详情能直接命中图片缓存、不再二次下载。
      cover: firstString(data, coverKeys),
      author: author.isNotEmpty ? author : firstString(data, ['author']),
      abstract: firstString(data, ['abstract', 'intro', 'description']),
      category: category.isNotEmpty
          ? category
          : (tags.isNotEmpty ? tags.first : ''),
      creationStatus: asInt(data['creation_status'], -1),
      wordNumber: asInt(data['word_number']),
      serialCount: asInt(
        data['content_chapter_number'],
        asInt(data['serial_count']),
      ),
      readCount: firstString(data, ['read_count', 'read_count_all']),
      score: firstString(data, ['score']),
      tags: tags,
      lastChapterTitle: firstString(data, ['last_chapter_title']),
      rankTitle: firstString(data, ['rank_title']),
    );
  }

  bool get isEmpty => bookId.isEmpty && title.isEmpty;
}
