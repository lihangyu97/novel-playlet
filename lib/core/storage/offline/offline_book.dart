import '../../../data/models/chapter.dart';
import '../../../data/models/json_utils.dart';

/// 离线 manifest 的 schema 版本。读不懂的版本一律当没有（不删文件，交给用户
/// 手动清理），见 docs/offline-cache.md §4.3 / §9。
const int offlineSchema = 1;

/// manifest 的 kind 取值（与文件名/目录布局对应）。
const String offlineKindNovel = 'novel';
const String offlineKindVideo = 'video';

/// 小说 manifest 里的一章（只存目录信息，正文在单独的章节 JSON 里）。
class OfflineChapter {
  const OfflineChapter({
    required this.id,
    required this.title,
    this.volumeName = '',
    this.index = 0,
  });

  final String id;
  final String title;
  final String volumeName;

  /// 在整本目录里的序号（0 基）。
  final int index;

  factory OfflineChapter.fromChapter(Chapter chapter) => OfflineChapter(
    id: chapter.id,
    title: chapter.title,
    volumeName: chapter.volumeName,
    index: chapter.index,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'volumeName': volumeName,
    'index': index,
  };

  static OfflineChapter? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final id = firstString(json, ['id', 'item_id', 'chapter_id']);
    if (id.isEmpty) return null;
    return OfflineChapter(
      id: id,
      title: firstString(json, ['title', 'name']),
      volumeName: firstString(json, ['volumeName', 'volume_name']),
      index: asInt(json['index']),
    );
  }
}

/// 小说离线 manifest（`novel/<bookKey>/book.json`，见 §4.3）。
class OfflineBook {
  OfflineBook({
    this.schema = offlineSchema,
    this.kind = offlineKindNovel,
    required this.bookId,
    required this.title,
    this.cover = '',
    required List<OfflineChapter> chapters,
    this.completed = 0,
    this.bytes = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : chapters = List<OfflineChapter>.unmodifiable(chapters),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final int schema;
  final String kind;
  final String bookId;
  final String title;
  final String cover;
  final List<OfflineChapter> chapters;

  /// 已落盘章数（reconcile 会按文件存在校正，可能偏小）。
  final int completed;

  /// 章节文件字节数之和（reconcile 校正）。
  final int bytes;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 总章数以 manifest 的 chapters 列表为准，避免两个字段打架。
  int get total => chapters.length;

  bool get isComplete => total > 0 && completed >= total;

  OfflineBook copyWith({
    String? title,
    String? cover,
    List<OfflineChapter>? chapters,
    int? completed,
    int? bytes,
    DateTime? updatedAt,
  }) => OfflineBook(
    schema: schema,
    kind: kind,
    bookId: bookId,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    chapters: chapters ?? this.chapters,
    completed: completed ?? this.completed,
    bytes: bytes ?? this.bytes,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'kind': kind,
    'bookId': bookId,
    'title': title,
    'cover': cover,
    'chapters': [for (final chapter in chapters) chapter.toJson()],
    'completed': completed,
    'total': total,
    'bytes': bytes,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  /// 解析 manifest；schema/kind 不匹配或结构损坏返回 null（当没有缓存）。
  static OfflineBook? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    if (asInt(json['schema']) != offlineSchema) return null;
    if (asString(json['kind']) != offlineKindNovel) return null;
    final bookId = firstString(json, ['bookId', 'book_id']);
    if (bookId.isEmpty) return null;
    final chapters = <OfflineChapter>[];
    for (final entry in asList(json['chapters'])) {
      final chapter = OfflineChapter.tryFromJson(entry);
      if (chapter != null) chapters.add(chapter);
    }
    return OfflineBook(
      bookId: bookId,
      title: asString(json['title']),
      cover: asString(json['cover']),
      chapters: chapters,
      completed: asInt(json['completed']),
      bytes: asInt(json['bytes']),
      createdAt: _dateTime(json['createdAt']),
      updatedAt: _dateTime(json['updatedAt']),
    );
  }
}

/// 离线列表的一行（缓存中心列表用，只来自 manifest，不扫盘）。
class OfflineBookSummary {
  const OfflineBookSummary({
    required this.bookId,
    required this.title,
    required this.cover,
    required this.completed,
    required this.total,
    required this.bytes,
    required this.updatedAt,
  });

  final String bookId;
  final String title;
  final String cover;
  final int completed;
  final int total;
  final int bytes;
  final DateTime updatedAt;

  factory OfflineBookSummary.fromBook(OfflineBook book) => OfflineBookSummary(
    bookId: book.bookId,
    title: book.title,
    cover: book.cover,
    completed: book.completed,
    total: book.total,
    bytes: book.bytes,
    updatedAt: book.updatedAt,
  );
}

/// 一个离线区的统计（章节/剧集共用一个结构）。
class OfflineStats {
  const OfflineStats({
    required this.count,
    required this.bytes,
    required this.capBytes,
  });

  /// 区内条目数（小说：本数；短剧：部数）。
  final int count;
  final int bytes;
  final int capBytes;

  bool get isOverCap => bytes >= capBytes;

  /// 0~1 的占用比例（cap 非法时按 0）。
  double get usedRatio =>
      capBytes <= 0 ? 0 : (bytes / capBytes).clamp(0, 1).toDouble();

  OfflineStats copyWith({int? count, int? bytes, int? capBytes}) =>
      OfflineStats(
        count: count ?? this.count,
        bytes: bytes ?? this.bytes,
        capBytes: capBytes ?? this.capBytes,
      );

  @override
  bool operator ==(Object other) =>
      other is OfflineStats &&
      other.count == count &&
      other.bytes == bytes &&
      other.capBytes == capBytes;

  @override
  int get hashCode => Object.hash(count, bytes, capBytes);
}

DateTime _dateTime(Object? value) {
  final millis = asInt(value);
  return millis > 0 ? DateTime.fromMillisecondsSinceEpoch(millis) : DateTime(0);
}
