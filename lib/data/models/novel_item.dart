import 'json_utils.dart';

/// 推荐/搜索里的一张小说卡片。
///
/// 上游把同一本书放在 `book_data`（对象或数组）里，也有的 cell 直接把字段
/// 挂在卡片上，所以 `fromRaw` 只做"在哪一层找到这些字段"的兼容。
class NovelItem {
  const NovelItem({
    required this.id,
    required this.title,
    this.cover = '',
    this.author = '',
    this.intro = '',
    this.category = '',
    this.wordCount = 0,
    this.score = '',
    this.lastChapter = '',
  });

  final String id;
  final String title;
  final String cover;
  final String author;
  final String intro;
  final String category;
  final int wordCount;
  final String score;
  final String lastChapter;

  bool get isValid => id.isNotEmpty && title.isNotEmpty;

  /// 卡片字段优先，其次 `book_data` 内层。
  factory NovelItem.fromRaw(Map<String, dynamic> raw) {
    final inner = asMap(raw['book_data']) ?? raw;
    final id = firstString(inner, ['book_id', 'item_id', 'id', 'cell_id']);
    final title = firstString(inner, [
      'book_name',
      'title',
      'name',
      'raw_book_name',
    ]);
    return NovelItem(
      id: id.isEmpty
          ? firstString(raw, ['book_id', 'item_id', 'id', 'cell_id'])
          : id,
      title: title.isEmpty ? firstString(raw, ['title', 'name', 'cell_name']) : title,
      cover: firstString(inner, [
        'thumb_url',
        'cover',
        'cover_url',
        'detail_page_thumb_url',
      ]),
      author: firstString(inner, ['author', 'author_name']),
      intro: firstString(inner, ['abstract', 'intro', 'description', 'book_abstract']),
      category: firstString(inner, ['category', 'category_name', 'badge']),
      wordCount: asInt(inner['word_number']),
      score: asString(inner['score']),
      lastChapter: firstString(inner, ['last_chapter_title', 'last_chapter']),
    );
  }

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'author': author,
    'category': category,
  };

  static NovelItem fromStorageJson(Map<String, dynamic> json) => NovelItem(
    id: asString(json['id']),
    title: asString(json['title']),
    cover: asString(json['cover']),
    author: asString(json['author']),
    category: asString(json['category']),
  );
}

/// 一页推荐/搜索结果。
class NovelFeedPage {
  const NovelFeedPage({
    required this.items,
    this.nextOffset,
    this.sessionId,
  });

  final List<NovelItem> items;

  /// 下一页游标。上游用它而不是页码；没有则视为到底。
  final int? nextOffset;
  final String? sessionId;

  bool get hasMore => nextOffset != null && nextOffset! > 0;
}
