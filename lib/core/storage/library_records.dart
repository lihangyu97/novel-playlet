import 'dart:math' as math;

import '../../data/models/json_utils.dart';

/// 内容类型。`wire` 直接进 SQLite 与同步 JSON，不要改字面量。
enum LibraryType {
  novel('novel'),
  playlet('playlet');

  const LibraryType(this.wire);

  final String wire;

  bool get isPlaylet => this == LibraryType.playlet;

  static LibraryType? tryParse(Object? value) {
    final wire = asString(value);
    for (final type in LibraryType.values) {
      if (type.wire == wire) return type;
    }
    return null;
  }
}

/// 一条内容记录：小说与短剧共用一张表，靠 [type] 区分。
///
/// 主键是 [key]（`'$type/$id'`）——小说用 `book_id`、短剧用 `series_id`，
/// 两者来自不同上游域，裸 id 可能撞号，所以不能拿 id 当主键。
///
/// 字段分三组，合并规则见 [mergeLibraryRecords]：
/// - 上游快照：整组按 [metaFetchedAt] 取新；
/// - 进度：整组按 [lastReadAt] 取新；
/// - 书架：`shelfAt` / `shelfRemovedAt` 各取 max，`shelfAt > shelfRemovedAt` 才算在架。
class LibraryRecord {
  const LibraryRecord({
    required this.type,
    required this.sourceId,
    this.title = '',
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.colorDominate = '',
    this.metaFetchedAt = 0,
    this.lastReadAt = 0,
    this.progressRef = '',
    this.progressIndex = 0,
    this.progressSub = 0,
    this.shelfAt = 0,
    this.shelfRemovedAt = 0,
  });

  final LibraryType type;

  /// 上游 id（小说 `book_id` / 短剧 `series_id`），不含类型前缀。
  final String sourceId;

  // ---- 上游快照 ----
  final String title;

  /// 小说作者；短剧为空。
  final String author;
  final String cover;

  /// 短剧简介；小说为空。
  final String intro;

  /// 短剧集数；小说为 0。
  final int episodeCount;
  final String colorDominate;
  final int metaFetchedAt;

  // ---- 进度 ----
  final int lastReadAt;

  /// 小说是 `chapterId`；短剧留空（集数放 [progressIndex]）。
  final String progressRef;

  /// 小说章节序号 / 短剧集数（0-based）。
  final int progressIndex;

  /// 小说章节内段落下标；短剧为 0。
  final int progressSub;

  // ---- 书架 / 收藏 ----
  final int shelfAt;
  final int shelfRemovedAt;

  String get key => '${type.wire}/$sourceId';

  bool get onShelf => shelfAt > 0 && shelfAt > shelfRemovedAt;

  /// 移出过书架且没再加回来 = 墓碑行。
  ///
  /// 墓碑只表示"不在书架/收藏里"，不等于"从历史里消失"：移出后继续读的书
  /// 仍有 `lastReadAt > shelfRemovedAt`，会重新出现在「历史」并保留快照。
  bool get isTombstone => shelfRemovedAt > 0 && shelfRemovedAt >= shelfAt;

  bool get hasProgress => lastReadAt > 0;

  bool get hasMeta => title.isNotEmpty || cover.isNotEmpty;

  /// 移出书架后是否又读过：这种行要留在「历史」里，快照不能清。
  ///
  /// 注意是严格大于：删书架时 `shelfRemovedAt` 一定大于当时的 `lastReadAt`，
  /// 所以"移出后没再读"的墓碑仍然是可瘦身的。
  bool get hasProgressAfterRemoval =>
      isTombstone && lastReadAt > shelfRemovedAt;

  /// 墓碑瘦身：只留 id / 时间戳 / 进度，快照列全清。
  ///
  /// 移出书架且之后没再读的内容不再出现在「历史 / 收藏」里，书名封面用不上了；
  /// 清掉之后单行从约 370 B 降到约 90 B，同步载荷同步变小。
  /// 真正需要"删掉"这个事实时仍然靠 `shelfRemovedAt`，行本身不删。
  LibraryRecord normalized() {
    if (!isTombstone || hasProgressAfterRemoval) return this;
    return copyWith(
      title: '',
      author: '',
      cover: '',
      intro: '',
      episodeCount: 0,
      colorDominate: '',
      metaFetchedAt: 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type.wire,
    'id': sourceId,
    if (title.isNotEmpty) 'title': title,
    if (author.isNotEmpty) 'author': author,
    if (cover.isNotEmpty) 'cover': cover,
    if (intro.isNotEmpty) 'intro': intro,
    if (episodeCount > 0) 'episodeCount': episodeCount,
    if (colorDominate.isNotEmpty) 'colorDominate': colorDominate,
    if (metaFetchedAt > 0) 'metaFetchedAt': metaFetchedAt,
    if (lastReadAt > 0) 'lastReadAt': lastReadAt,
    // 进度按内容类型用可读的字段名，落库时统一进 progress_* 三列。
    if (type == LibraryType.novel) ...{
      if (progressRef.isNotEmpty) 'chapterId': progressRef,
      if (progressIndex > 0) 'chapterIndex': progressIndex,
      if (progressSub > 0) 'blockIndex': progressSub,
    } else ...{
      if (progressIndex > 0) 'episodeIndex': progressIndex,
    },
    if (shelfAt > 0) 'shelfAt': shelfAt,
    if (shelfRemovedAt > 0) 'shelfRemovedAt': shelfRemovedAt,
  };

  static LibraryRecord? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final type = LibraryType.tryParse(json['type']);
    final sourceId = asString(json['id']);
    if (type == null || sourceId.isEmpty) return null;
    return LibraryRecord(
      type: type,
      sourceId: sourceId,
      title: asString(json['title']),
      author: asString(json['author']),
      cover: asString(json['cover']),
      intro: asString(json['intro']),
      episodeCount: asInt(json['episodeCount']),
      colorDominate: asString(json['colorDominate']),
      metaFetchedAt: asInt(json['metaFetchedAt']),
      lastReadAt: asInt(json['lastReadAt']),
      progressRef: asString(json['chapterId']),
      progressIndex: type.isPlaylet
          ? asInt(json['episodeIndex'])
          : asInt(json['chapterIndex']),
      progressSub: type.isPlaylet ? 0 : asInt(json['blockIndex']),
      shelfAt: asInt(json['shelfAt']),
      shelfRemovedAt: asInt(json['shelfRemovedAt']),
    );
  }

  LibraryRecord copyWith({
    String? title,
    String? author,
    String? cover,
    String? intro,
    int? episodeCount,
    String? colorDominate,
    int? metaFetchedAt,
    int? lastReadAt,
    String? progressRef,
    int? progressIndex,
    int? progressSub,
    int? shelfAt,
    int? shelfRemovedAt,
  }) => LibraryRecord(
    type: type,
    sourceId: sourceId,
    title: title ?? this.title,
    author: author ?? this.author,
    cover: cover ?? this.cover,
    intro: intro ?? this.intro,
    episodeCount: episodeCount ?? this.episodeCount,
    colorDominate: colorDominate ?? this.colorDominate,
    metaFetchedAt: metaFetchedAt ?? this.metaFetchedAt,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    progressRef: progressRef ?? this.progressRef,
    progressIndex: progressIndex ?? this.progressIndex,
    progressSub: progressSub ?? this.progressSub,
    shelfAt: shelfAt ?? this.shelfAt,
    shelfRemovedAt: shelfRemovedAt ?? this.shelfRemovedAt,
  );

  /// 任何一个参与合并的字段是否不同（决定要不要落盘、要不要 bump revision）。
  ///
  /// 必须逐字段比：`shelfAt` / `shelfRemovedAt` 取 max 后"是否在架"可能没变但
  /// 时间戳变了；不落盘的话本地导出会和远端永远差一个值，两端每次同步各传一版。
  bool diffFrom(LibraryRecord other) =>
      title != other.title ||
      author != other.author ||
      cover != other.cover ||
      intro != other.intro ||
      episodeCount != other.episodeCount ||
      colorDominate != other.colorDominate ||
      metaFetchedAt != other.metaFetchedAt ||
      lastReadAt != other.lastReadAt ||
      progressRef != other.progressRef ||
      progressIndex != other.progressIndex ||
      progressSub != other.progressSub ||
      shelfAt != other.shelfAt ||
      shelfRemovedAt != other.shelfRemovedAt;

  /// 书架状态是否变化（用于 bump shelfRevision）。
  bool shelfDiffersFrom(LibraryRecord other) =>
      onShelf != other.onShelf || shelfRemovedAt != other.shelfRemovedAt;

  /// 进度是否变化（用于 bump historyRevision）。
  bool progressDiffersFrom(LibraryRecord other) =>
      lastReadAt != other.lastReadAt || progressRef != other.progressRef;
}

/// 快照整组该取哪一侧：时间戳大的；相等时优先非空，再相等取远端（两端看到
/// 同一个远端文件，因此一定收敛）。
bool _preferRemoteMeta(LibraryRecord local, LibraryRecord remote) {
  if (remote.metaFetchedAt > local.metaFetchedAt) return true;
  if (remote.metaFetchedAt < local.metaFetchedAt) return false;
  if (!remote.hasMeta && local.hasMeta) return false;
  return true;
}

/// 同一条记录的合并（[local] 与 [remote] 的 [LibraryRecord.key] 必须相同）。
///
/// 返回结果已经过 [LibraryRecord.normalized]：墓碑行不留快照。
LibraryRecord mergeLibraryRecords(LibraryRecord local, LibraryRecord remote) {
  final meta = _preferRemoteMeta(local, remote) ? remote : local;

  // 进度整组取新；时间戳相等时优先"有进度"的一侧，再相等取远端。
  final progress = remote.lastReadAt > local.lastReadAt
      ? remote
      : remote.lastReadAt < local.lastReadAt
      ? local
      : (!remote.hasProgress && local.hasProgress)
      ? local
      : remote;

  return LibraryRecord(
    type: local.type,
    sourceId: local.sourceId,
    title: meta.title,
    author: meta.author,
    cover: meta.cover,
    intro: meta.intro,
    episodeCount: meta.episodeCount,
    colorDominate: meta.colorDominate,
    metaFetchedAt: math.max(local.metaFetchedAt, remote.metaFetchedAt),
    lastReadAt: progress.lastReadAt,
    progressRef: progress.progressRef,
    progressIndex: progress.progressIndex,
    progressSub: progress.progressSub,
    shelfAt: math.max(local.shelfAt, remote.shelfAt),
    shelfRemovedAt: math.max(local.shelfRemovedAt, remote.shelfRemovedAt),
  ).normalized();
}
