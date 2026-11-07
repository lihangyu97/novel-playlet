import '../../../data/models/chapter.dart';
import '../../../data/models/json_utils.dart';
import 'offline_book.dart';

/// 短剧 manifest 里的一集（只存元信息，明文 mp4 在单独文件里）。
class OfflineEpisode {
  const OfflineEpisode({
    required this.id,
    required this.title,
    this.index = 0,
    this.bytes = 0,
    this.cached = false,
    this.variantName = '',
    this.shortEdge = 0,
  });

  final String id;
  final String title;
  final int index;

  /// 已落盘明文 mp4 的字节数（未缓存为 0）。
  final int bytes;

  /// 文件是否已落盘（reconcile 按文件存在校正）。
  final bool cached;

  /// 下载时实际命中/请求到的清晰度（如 `720P`）；旧 manifest 为空。
  final String variantName;

  /// 实际档位的短边（360/480/720/1080）；0 表示未知。
  final int shortEdge;

  factory OfflineEpisode.fromChapter(Chapter chapter) => OfflineEpisode(
    id: chapter.id,
    title: chapter.title,
    index: chapter.index,
  );

  OfflineEpisode copyWith({
    int? bytes,
    bool? cached,
    String? variantName,
    int? shortEdge,
  }) => OfflineEpisode(
    id: id,
    title: title,
    index: index,
    bytes: bytes ?? this.bytes,
    cached: cached ?? this.cached,
    variantName: variantName ?? this.variantName,
    shortEdge: shortEdge ?? this.shortEdge,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'index': index,
    'bytes': bytes,
    'cached': cached,
    if (variantName.isNotEmpty) 'variantName': variantName,
    if (shortEdge > 0) 'shortEdge': shortEdge,
  };

  static OfflineEpisode? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final id = firstString(json, ['id', 'item_id', 'episode_id']);
    if (id.isEmpty) return null;
    return OfflineEpisode(
      id: id,
      title: firstString(json, ['title', 'name']),
      index: asInt(json['index']),
      bytes: asInt(json['bytes']),
      cached: json['cached'] == true,
      variantName: asString(json['variantName']),
      shortEdge: asInt(json['shortEdge']),
    );
  }
}

/// 短剧离线 manifest（`video/<seriesKey>/series.json`，见 §4.3）。
class OfflineSeries {
  OfflineSeries({
    this.schema = offlineSchema,
    this.kind = offlineKindVideo,
    required this.seriesId,
    required this.title,
    this.cover = '',
    required List<OfflineEpisode> episodes,
    this.completed = 0,
    this.bytes = 0,
    this.qualityMaxHeight = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : episodes = List<OfflineEpisode>.unmodifiable(episodes),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final int schema;
  final String kind;
  final String seriesId;
  final String title;
  final String cover;
  final List<OfflineEpisode> episodes;

  /// 已缓存集数（reconcile 按文件存在校正）。
  final int completed;

  /// 明文 mp4 字节数之和。
  final int bytes;

  /// 下载时请求的清晰度上限（0 = 最高档；720 = 默认）。实际档位以每集
  /// `variantName` 为准（同剧不同集可能有差异）。
  final int qualityMaxHeight;

  final DateTime createdAt;
  final DateTime updatedAt;

  int get total => episodes.length;

  bool get isComplete => total > 0 && completed >= total;

  OfflineSeries copyWith({
    String? title,
    String? cover,
    List<OfflineEpisode>? episodes,
    int? completed,
    int? bytes,
    int? qualityMaxHeight,
    DateTime? updatedAt,
  }) => OfflineSeries(
    schema: schema,
    kind: kind,
    seriesId: seriesId,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    episodes: episodes ?? this.episodes,
    completed: completed ?? this.completed,
    bytes: bytes ?? this.bytes,
    qualityMaxHeight: qualityMaxHeight ?? this.qualityMaxHeight,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'kind': kind,
    'seriesId': seriesId,
    'title': title,
    'cover': cover,
    'episodes': [for (final episode in episodes) episode.toJson()],
    'completed': completed,
    'total': total,
    'bytes': bytes,
    if (qualityMaxHeight > 0) 'qualityMaxHeight': qualityMaxHeight,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  /// 解析 manifest；schema/kind 不匹配或结构损坏返回 null（当没有缓存）。
  static OfflineSeries? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    if (asInt(json['schema']) != offlineSchema) return null;
    if (asString(json['kind']) != offlineKindVideo) return null;
    final seriesId = firstString(json, ['seriesId', 'series_id']);
    if (seriesId.isEmpty) return null;
    final episodes = <OfflineEpisode>[];
    for (final entry in asList(json['episodes'])) {
      final episode = OfflineEpisode.tryFromJson(entry);
      if (episode != null) episodes.add(episode);
    }
    return OfflineSeries(
      seriesId: seriesId,
      title: asString(json['title']),
      cover: asString(json['cover']),
      episodes: episodes,
      completed: asInt(json['completed']),
      bytes: asInt(json['bytes']),
      qualityMaxHeight: asInt(json['qualityMaxHeight']),
      createdAt: _dateTime(json['createdAt']),
      updatedAt: _dateTime(json['updatedAt']),
    );
  }
}

/// 短剧离线列表的一行（只来自 manifest，不扫盘）。
class OfflineSeriesSummary {
  const OfflineSeriesSummary({
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.completed,
    required this.total,
    required this.bytes,
    required this.updatedAt,
    this.qualityLabel = '',
  });

  final String seriesId;
  final String title;
  final String cover;
  final int completed;
  final int total;
  final int bytes;
  final DateTime updatedAt;

  /// 缓存实际清晰度（如 `720P`）；旧 manifest/未知为空。
  final String qualityLabel;

  factory OfflineSeriesSummary.fromSeries(OfflineSeries series) =>
      OfflineSeriesSummary(
        seriesId: series.seriesId,
        title: series.title,
        cover: series.cover,
        completed: series.completed,
        total: series.total,
        bytes: series.bytes,
        updatedAt: series.updatedAt,
        qualityLabel: qualityLabelOf(series),
      );
}

/// 缓存清晰度展示文案：优先用第一集的实际档位，其次用请求上限。
String qualityLabelOf(OfflineSeries series) {
  for (final episode in series.episodes) {
    if (episode.variantName.isNotEmpty) return episode.variantName;
  }
  final maxHeight = series.qualityMaxHeight;
  if (maxHeight <= 0) return '';
  if (maxHeight <= 480) return '480P';
  if (maxHeight <= 720) return '720P';
  if (maxHeight <= 1080) return '1080P';
  return '${maxHeight}P';
}

DateTime _dateTime(Object? value) {
  final millis = asInt(value);
  return millis > 0 ? DateTime.fromMillisecondsSinceEpoch(millis) : DateTime(0);
}
