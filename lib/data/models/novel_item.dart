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
    this.recommendReason = '',
    this.rankScore = '',
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

  /// 推荐理由（`recommend_reason_list` 第一条，如「巅峰榜No.3」「19个老书虫在看」）。
  final String recommendReason;

  /// 热度（`rank_score`，如「8479万热度」）；没有推荐理由时用它。
  final String rankScore;

  bool get isValid => id.isNotEmpty && title.isNotEmpty;

  /// 卡片字段优先，其次 `book_data` 内层。
  factory NovelItem.fromRaw(Map<String, dynamic> raw) {
    final inner = asMap(raw['book_data']) ?? raw;
    // cell_id 是区块 id，不是书 id（排行榜区块也带它），不参与回退。
    final id = firstString(inner, ['book_id', 'item_id', 'id']);
    final title = firstString(inner, [
      'book_name',
      'title',
      'name',
      'raw_book_name',
    ]);
    // 封面和 id/title 一样要回退到卡片层：有的 card 把 thumb_url 挂在外层、
    // book_data 里只放书名，只看内层会白丢一张图。
    final cover = firstString(inner, coverKeys);
    return NovelItem(
      id: id.isEmpty ? firstString(raw, ['book_id', 'item_id', 'id']) : id,
      title: title.isEmpty ? firstString(raw, ['title', 'name']) : title,
      cover: cover.isNotEmpty ? cover : firstString(raw, coverKeys),
      author: firstString(inner, ['author', 'author_name']),
      intro: firstString(inner, [
        'abstract',
        'intro',
        'description',
        'book_abstract',
      ]),
      category: firstString(inner, ['category', 'category_name', 'badge']),
      wordCount: asInt(inner['word_number']),
      score: asString(inner['score']),
      lastChapter: firstString(inner, ['last_chapter_title', 'last_chapter']),
      recommendReason: firstReasonText(inner['recommend_reason_list']),
      rankScore: firstString(inner, ['rank_score']),
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

  /// 按"所有参与展示的字段"比较，不是只比 id：
  /// 同一本书在推荐区块和搜索 tab 里的封面 / 简介 / 字数可能一处缺、一处全，
  /// 按全字段比较才能让 diff / select 发现内容更新；需要按 id 去重的地方
  /// （列表追加、收藏）由调用方显式用 [id]。
  @override
  bool operator ==(Object other) =>
      other is NovelItem &&
      other.id == id &&
      other.title == title &&
      other.cover == cover &&
      other.author == author &&
      other.intro == intro &&
      other.category == category &&
      other.wordCount == wordCount &&
      other.score == score &&
      other.lastChapter == lastChapter &&
      other.recommendReason == recommendReason &&
      other.rankScore == rankScore;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    cover,
    author,
    intro,
    category,
    wordCount,
    score,
    lastChapter,
    recommendReason,
    rankScore,
  );
}
