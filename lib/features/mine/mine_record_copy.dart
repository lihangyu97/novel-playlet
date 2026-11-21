import '../../core/storage/library_records.dart';

/// 我的页历史 / 收藏共用的条目文案。
///
/// 页面上的列表、全量弹窗都从这里取副标题，避免「读到第 N 章」和
/// 「全 N 集」两套口径在多个文件里各写一遍。
String mineHistorySubtitle(LibraryRecord item) {
  if (item.type.isPlaylet) {
    return '看到第 ${item.progressIndex + 1} 集';
  }
  if (item.progressRef.isEmpty) return '尚未开始阅读';
  return '读到第 ${item.progressIndex + 1} 章';
}

/// 收藏卡片的元信息：小说作者 / 短剧集数；没有就返回空串（卡片不占这一行）。
String mineCollectionMeta(LibraryRecord item) {
  if (item.type.isPlaylet) {
    return item.episodeCount > 0 ? '全 ${item.episodeCount} 集' : '';
  }
  return item.author;
}

/// 全量收藏列表的副标题：元信息为空时至少交代类型，列表行不留空行。
String mineCollectionSubtitle(LibraryRecord item) {
  final meta = mineCollectionMeta(item);
  if (meta.isNotEmpty) return meta;
  return item.type.isPlaylet ? '短剧' : '小说';
}
