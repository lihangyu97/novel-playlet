import 'dart:math' as math;

import '../../data/models/json_utils.dart';

/// 一条小说库记录：**上游快照**（title/author/cover/…）+ **用户状态**（书架/进度）。
///
/// 字段语义与合并规则见 `docs/storage-model-proposal.md` §3~§4，核心三条：
/// - 快照整组按 [metaFetchedAt] 取新（相等取远端），不做逐字段合并；
/// - [lastReadAt] 是进度组的时间戳，章节三列跟着它整组取，不会出现"时间取自
///   A、位置取自 B"；
/// - [shelfAt] / [shelfRemovedAt] 各自取 max，[shelfAt] > [shelfRemovedAt]
///   才算在架上——删除因此可表达，也不会被远端旧值复活。
class NovelRecord {
  const NovelRecord({
    required this.id,
    this.title = '',
    this.author = '',
    this.cover = '',
    this.colorDominate = '',
    this.metaFetchedAt = 0,
    this.lastReadAt = 0,
    this.chapterId = '',
    this.chapterIndex = 0,
    this.blockIndex = 0,
    this.shelfAt = 0,
    this.shelfRemovedAt = 0,
  });

  final String id;

  // ---- 上游快照（写一次，可按需刷新） ----
  final String title;
  final String author;
  final String cover;
  final String colorDominate;
  final int metaFetchedAt;

  // ---- 用户状态：进度 ----
  final int lastReadAt;
  final String chapterId;
  final int chapterIndex;
  final int blockIndex;

  // ---- 用户状态：书架 ----
  final int shelfAt;
  final int shelfRemovedAt;

  bool get onShelf => shelfAt > 0 && shelfAt > shelfRemovedAt;

  bool get hasProgress => lastReadAt > 0 && chapterId.isNotEmpty;

  bool get hasMeta => title.isNotEmpty || cover.isNotEmpty;

  /// 只写非空字段：既省同步载荷，也让判等（合并后是否需要落盘）更稳。
  Map<String, dynamic> toJson() => {
    'id': id,
    if (title.isNotEmpty) 'title': title,
    if (author.isNotEmpty) 'author': author,
    if (cover.isNotEmpty) 'cover': cover,
    if (colorDominate.isNotEmpty) 'colorDominate': colorDominate,
    if (metaFetchedAt > 0) 'metaFetchedAt': metaFetchedAt,
    if (lastReadAt > 0) 'lastReadAt': lastReadAt,
    if (chapterId.isNotEmpty) 'chapterId': chapterId,
    if (chapterIndex > 0) 'chapterIndex': chapterIndex,
    if (blockIndex > 0) 'blockIndex': blockIndex,
    if (shelfAt > 0) 'shelfAt': shelfAt,
    if (shelfRemovedAt > 0) 'shelfRemovedAt': shelfRemovedAt,
  };

  static NovelRecord? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final id = asString(json['id']);
    if (id.isEmpty) return null;
    return NovelRecord(
      id: id,
      title: asString(json['title']),
      author: asString(json['author']),
      cover: asString(json['cover']),
      colorDominate: asString(json['colorDominate']),
      metaFetchedAt: asInt(json['metaFetchedAt']),
      lastReadAt: asInt(json['lastReadAt']),
      chapterId: asString(json['chapterId']),
      chapterIndex: asInt(json['chapterIndex']),
      blockIndex: asInt(json['blockIndex']),
      shelfAt: asInt(json['shelfAt']),
      shelfRemovedAt: asInt(json['shelfRemovedAt']),
    );
  }

  NovelRecord copyWith({
    String? title,
    String? author,
    String? cover,
    String? colorDominate,
    int? metaFetchedAt,
    int? lastReadAt,
    String? chapterId,
    int? chapterIndex,
    int? blockIndex,
    int? shelfAt,
    int? shelfRemovedAt,
  }) => NovelRecord(
    id: id,
    title: title ?? this.title,
    author: author ?? this.author,
    cover: cover ?? this.cover,
    colorDominate: colorDominate ?? this.colorDominate,
    metaFetchedAt: metaFetchedAt ?? this.metaFetchedAt,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    chapterId: chapterId ?? this.chapterId,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    blockIndex: blockIndex ?? this.blockIndex,
    shelfAt: shelfAt ?? this.shelfAt,
    shelfRemovedAt: shelfRemovedAt ?? this.shelfRemovedAt,
  );

  /// 任何一个参与合并的字段是否不同（决定要不要落盘、要不要 bump revision）。
  ///
  /// 必须逐字段比，不能退化成只比 `onShelf`：`shelfAt` / `shelfRemovedAt` 取
  /// max 后"是否在架"可能没变但时间戳变了；这类改动不落盘的话，本地导出会和
  /// 远端始终差一个值，两端各自上传自己的版本 → 每次同步都白传一遍。
  bool diffFrom(NovelRecord other) =>
      title != other.title ||
      author != other.author ||
      cover != other.cover ||
      colorDominate != other.colorDominate ||
      metaFetchedAt != other.metaFetchedAt ||
      lastReadAt != other.lastReadAt ||
      chapterId != other.chapterId ||
      chapterIndex != other.chapterIndex ||
      blockIndex != other.blockIndex ||
      shelfAt != other.shelfAt ||
      shelfRemovedAt != other.shelfRemovedAt;
}

/// 一条短剧库记录；与 [NovelRecord] 同构，进度换成"第几集"。
class VideoRecord {
  const VideoRecord({
    required this.id,
    this.title = '',
    this.cover = '',
    this.intro = '',
    this.episodeCount = 0,
    this.colorDominate = '',
    this.metaFetchedAt = 0,
    this.lastReadAt = 0,
    this.episodeIndex = 0,
    this.shelfAt = 0,
    this.shelfRemovedAt = 0,
  });

  final String id;

  final String title;
  final String cover;
  final String intro;
  final int episodeCount;
  final String colorDominate;
  final int metaFetchedAt;

  final int lastReadAt;
  final int episodeIndex;

  final int shelfAt;
  final int shelfRemovedAt;

  bool get onShelf => shelfAt > 0 && shelfAt > shelfRemovedAt;

  bool get hasProgress => lastReadAt > 0;

  bool get hasMeta => title.isNotEmpty || cover.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    if (title.isNotEmpty) 'title': title,
    if (cover.isNotEmpty) 'cover': cover,
    if (intro.isNotEmpty) 'intro': intro,
    if (episodeCount > 0) 'episodeCount': episodeCount,
    if (colorDominate.isNotEmpty) 'colorDominate': colorDominate,
    if (metaFetchedAt > 0) 'metaFetchedAt': metaFetchedAt,
    if (lastReadAt > 0) 'lastReadAt': lastReadAt,
    if (episodeIndex > 0) 'episodeIndex': episodeIndex,
    if (shelfAt > 0) 'shelfAt': shelfAt,
    if (shelfRemovedAt > 0) 'shelfRemovedAt': shelfRemovedAt,
  };

  static VideoRecord? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final id = asString(json['id']);
    if (id.isEmpty) return null;
    return VideoRecord(
      id: id,
      title: asString(json['title']),
      cover: asString(json['cover']),
      intro: asString(json['intro']),
      episodeCount: asInt(json['episodeCount']),
      colorDominate: asString(json['colorDominate']),
      metaFetchedAt: asInt(json['metaFetchedAt']),
      lastReadAt: asInt(json['lastReadAt']),
      episodeIndex: asInt(json['episodeIndex']),
      shelfAt: asInt(json['shelfAt']),
      shelfRemovedAt: asInt(json['shelfRemovedAt']),
    );
  }

  VideoRecord copyWith({
    String? title,
    String? cover,
    String? intro,
    int? episodeCount,
    String? colorDominate,
    int? metaFetchedAt,
    int? lastReadAt,
    int? episodeIndex,
    int? shelfAt,
    int? shelfRemovedAt,
  }) => VideoRecord(
    id: id,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    intro: intro ?? this.intro,
    episodeCount: episodeCount ?? this.episodeCount,
    colorDominate: colorDominate ?? this.colorDominate,
    metaFetchedAt: metaFetchedAt ?? this.metaFetchedAt,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    episodeIndex: episodeIndex ?? this.episodeIndex,
    shelfAt: shelfAt ?? this.shelfAt,
    shelfRemovedAt: shelfRemovedAt ?? this.shelfRemovedAt,
  );

  /// 规则同 [NovelRecord.diffFrom]：逐字段比，避免"取 max 后时间戳变了但
  /// 是否在架没变"这种改动不落盘、导致两端反复互传。
  bool diffFrom(VideoRecord other) =>
      title != other.title ||
      cover != other.cover ||
      intro != other.intro ||
      episodeCount != other.episodeCount ||
      colorDominate != other.colorDominate ||
      metaFetchedAt != other.metaFetchedAt ||
      lastReadAt != other.lastReadAt ||
      episodeIndex != other.episodeIndex ||
      shelfAt != other.shelfAt ||
      shelfRemovedAt != other.shelfRemovedAt;
}

/// 快照整组该取哪一侧：时间戳大的；相等时优先非空，再相等取远端（两端看到
/// 同一个远端文件，因此一定收敛）。
bool _preferRemoteMeta({
  required int localFetchedAt,
  required int remoteFetchedAt,
  required bool localEmpty,
  required bool remoteEmpty,
}) {
  if (remoteFetchedAt > localFetchedAt) return true;
  if (remoteFetchedAt < localFetchedAt) return false;
  if (remoteEmpty && !localEmpty) return false;
  return true;
}

/// 小说记录合并：快照整组、进度整组、书架时间戳各自取大。
NovelRecord mergeNovelRecords(NovelRecord local, NovelRecord remote) {
  final useRemoteMeta = _preferRemoteMeta(
    localFetchedAt: local.metaFetchedAt,
    remoteFetchedAt: remote.metaFetchedAt,
    localEmpty: !local.hasMeta,
    remoteEmpty: !remote.hasMeta,
  );
  final meta = useRemoteMeta ? remote : local;

  // 进度整组取新；时间戳相等时优先有进度的一侧，再相等取远端。
  final progress = remote.lastReadAt > local.lastReadAt
      ? remote
      : remote.lastReadAt < local.lastReadAt
      ? local
      : (!remote.hasProgress && local.hasProgress)
      ? local
      : remote;

  return NovelRecord(
    id: local.id,
    title: meta.title,
    author: meta.author,
    cover: meta.cover,
    colorDominate: meta.colorDominate,
    metaFetchedAt: math.max(local.metaFetchedAt, remote.metaFetchedAt),
    lastReadAt: progress.lastReadAt,
    chapterId: progress.chapterId,
    chapterIndex: progress.chapterIndex,
    blockIndex: progress.blockIndex,
    shelfAt: math.max(local.shelfAt, remote.shelfAt),
    shelfRemovedAt: math.max(local.shelfRemovedAt, remote.shelfRemovedAt),
  );
}

/// 短剧记录合并，规则同 [mergeNovelRecords]。
VideoRecord mergeVideoRecords(VideoRecord local, VideoRecord remote) {
  final useRemoteMeta = _preferRemoteMeta(
    localFetchedAt: local.metaFetchedAt,
    remoteFetchedAt: remote.metaFetchedAt,
    localEmpty: !local.hasMeta,
    remoteEmpty: !remote.hasMeta,
  );
  final meta = useRemoteMeta ? remote : local;

  final progress = remote.lastReadAt > local.lastReadAt
      ? remote
      : remote.lastReadAt < local.lastReadAt
      ? local
      : (!remote.hasProgress && local.hasProgress)
      ? local
      : remote;

  return VideoRecord(
    id: local.id,
    title: meta.title,
    cover: meta.cover,
    intro: meta.intro,
    episodeCount: meta.episodeCount,
    colorDominate: meta.colorDominate,
    metaFetchedAt: math.max(local.metaFetchedAt, remote.metaFetchedAt),
    lastReadAt: progress.lastReadAt,
    episodeIndex: progress.episodeIndex,
    shelfAt: math.max(local.shelfAt, remote.shelfAt),
    shelfRemovedAt: math.max(local.shelfRemovedAt, remote.shelfRemovedAt),
  );
}

// ---------------------------------------------------------------------------
// 旧格式（schemaVersion 1）转换
// ---------------------------------------------------------------------------

/// 把 v1 同步数据（`novelShelf` / `novelShelfMeta` / `novelProgress`）转成记录。
///
/// 两条用途：读旧的云端文件、以及首次启动时从 `shared_preferences` 迁移。
NovelRecord? _legacyNovel(
  Map<String, dynamic> shelfItem,
  Map<String, dynamic>? metaItem,
  Map<String, dynamic>? progressItem,
) {
  final id = asString(shelfItem['id']).isEmpty
      ? asString(progressItem?['bookId'])
      : asString(shelfItem['id']);
  if (id.isEmpty) return null;
  final deleted = metaItem?['d'] == true;
  final metaU = asInt(metaItem?['u']);
  // 只在进度表里出现过的书（没上过书架、也没有墓碑）：不能给 shelfAt 兜底，
  // 否则升级后"读过但没加书架"的书会凭空出现在书架上。
  final onShelfEntry = shelfItem.isNotEmpty || metaItem != null;
  return NovelRecord(
    id: id,
    title: asString(shelfItem['title']).isEmpty
        ? asString(progressItem?['bookTitle'])
        : asString(shelfItem['title']),
    author: asString(shelfItem['author']),
    cover: asString(shelfItem['cover']).isEmpty
        ? asString(progressItem?['cover'])
        : asString(shelfItem['cover']),
    colorDominate: asString(shelfItem['colorDominate']),
    lastReadAt: asInt(progressItem?['updatedAt']),
    chapterId: asString(progressItem?['chapterId']),
    chapterIndex: asInt(progressItem?['chapterIndex']),
    blockIndex: asInt(progressItem?['blockIndex']),
    // 老书架可能只有列表、没有同步元数据（`u` 缺省为 0）：用 1 兜底，
    // 否则 `shelfAt > 0` 不成立，升级后书架会整体消失。
    shelfAt: deleted || !onShelfEntry ? 0 : (metaU > 0 ? metaU : 1),
    shelfRemovedAt: deleted ? (metaU > 0 ? metaU : 1) : 0,
  );
}

VideoRecord? _legacyVideo(
  Map<String, dynamic> shelfItem,
  Map<String, dynamic>? metaItem,
  Map<String, dynamic>? progressItem,
) {
  final id = asString(shelfItem['id']).isEmpty
      ? asString(progressItem?['seriesId'])
      : asString(shelfItem['id']);
  if (id.isEmpty) return null;
  final deleted = metaItem?['d'] == true;
  final metaU = asInt(metaItem?['u']);
  final onShelfEntry = shelfItem.isNotEmpty || metaItem != null;
  return VideoRecord(
    id: id,
    title: asString(shelfItem['title']).isEmpty
        ? asString(progressItem?['title'])
        : asString(shelfItem['title']),
    cover: asString(shelfItem['cover']).isEmpty
        ? asString(progressItem?['cover'])
        : asString(shelfItem['cover']),
    intro: asString(shelfItem['intro']),
    episodeCount: asInt(shelfItem['episodeCount']),
    colorDominate: asString(shelfItem['colorDominate']),
    lastReadAt: asInt(progressItem?['updatedAt']),
    episodeIndex: asInt(progressItem?['episodeIndex']),
    shelfAt: deleted || !onShelfEntry ? 0 : (metaU > 0 ? metaU : 1),
    shelfRemovedAt: deleted ? (metaU > 0 ? metaU : 1) : 0,
  );
}

/// v1 的 `data` → 小说记录列表。
List<NovelRecord> novelRecordsFromLegacy(Map<String, dynamic> data) {
  final shelf = <String, Map<String, dynamic>>{};
  for (final raw in asList(data['novelShelf'])) {
    final json = asMap(raw);
    final id = asString(json?['id']);
    if (json != null && id.isNotEmpty) shelf[id] = json;
  }
  final meta = <String, Map<String, dynamic>>{};
  asMap(data['novelShelfMeta'])?.forEach((key, value) {
    final json = asMap(value);
    if (json != null) meta[key] = json;
  });
  final progress = <String, Map<String, dynamic>>{};
  asMap(data['novelProgress'])?.forEach((key, value) {
    final json = asMap(value);
    if (json != null) progress[key] = json;
  });

  final ids = <String>{...shelf.keys, ...meta.keys, ...progress.keys};
  final out = <NovelRecord>[];
  for (final id in ids) {
    final record = _legacyNovel(
      shelf[id] ?? const {},
      meta[id],
      progress[id],
    );
    if (record != null) out.add(record);
  }
  return out;
}

/// v1 的 `data` → 短剧记录列表。
List<VideoRecord> videoRecordsFromLegacy(Map<String, dynamic> data) {
  final shelf = <String, Map<String, dynamic>>{};
  for (final raw in asList(data['videoShelf'])) {
    final json = asMap(raw);
    final id = asString(json?['id']);
    if (json != null && id.isNotEmpty) shelf[id] = json;
  }
  final meta = <String, Map<String, dynamic>>{};
  asMap(data['videoShelfMeta'])?.forEach((key, value) {
    final json = asMap(value);
    if (json != null) meta[key] = json;
  });
  final progress = <String, Map<String, dynamic>>{};
  asMap(data['videoProgress'])?.forEach((key, value) {
    final json = asMap(value);
    if (json != null) progress[key] = json;
  });

  final ids = <String>{...shelf.keys, ...meta.keys, ...progress.keys};
  final out = <VideoRecord>[];
  for (final id in ids) {
    final record = _legacyVideo(
      shelf[id] ?? const {},
      meta[id],
      progress[id],
    );
    if (record != null) out.add(record);
  }
  return out;
}

/// 同步数据是新格式（`novel` / `video` 数组）还是 v1（`novelShelf` 等）。
bool isRecordPayload(Map<String, dynamic> data) =>
    data.containsKey('novel') || data.containsKey('video');
