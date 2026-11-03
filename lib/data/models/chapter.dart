import 'json_utils.dart';

/// 目录里的一个章节。
class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    this.volumeName = '',
    this.index = 0,
  });

  final String id;
  final String title;
  final String volumeName;

  /// 在整本目录里的序号（0 基），阅读器上一章/下一章按它走。
  final int index;

  factory Chapter.fromRaw(Map<String, dynamic> raw, {int? index}) => Chapter(
    id: firstString(raw, ['item_id', 'itemId', 'chapter_id', 'id']),
    title: firstString(raw, ['title', 'chapter_title', 'name']),
    volumeName: firstString(raw, ['volume_name', 'volumeName']),
    index: index ?? 0,
  );
}

/// 解析目录响应（`/api/v1/books/{id}/directory`）。
///
/// 上游小说目录在 `data.item_data_list`（或 `data.data.item_data_list`），
/// 卷信息在每条的 `volume_name` 上；没有卷对象，所以这里直接摊平成一维
/// 列表，保留 `volumeName` 供目录页插入卷标题。
List<Chapter> parseDirectory(Map<String, dynamic> payload) {
  final data = unwrapEnvelope(payload);
  dynamic entries = data['item_data_list'];
  entries ??= data['item_list'];
  entries ??= data['lists'];
  if (entries == null) {
    final inner = asMap(data['data']);
    entries = inner?['item_data_list'] ?? inner?['item_list'];
  }
  final chapters = <Chapter>[];
  for (final raw in asList(entries)) {
    final map = asMap(raw);
    if (map == null) continue;
    final chapter = Chapter.fromRaw(map, index: chapters.length);
    if (chapter.id.isEmpty) continue;
    chapters.add(chapter);
  }
  return chapters;
}
