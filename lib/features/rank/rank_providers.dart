import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/rank.dart';

/// 排行榜目录：藏在小说首页 payload 里，整个 App 进程内复用一份。
///
/// 2026-11 起首页不再展示榜单预览（短剧/漫剧的 catalog tab 也没了），
/// 榜单只从推荐页左上角图标进入 [RankPage]；目录仍按上游 payload 解析，
/// 失败由榜单页的错误态 + 重试负责。
final rankCatalogProvider = FutureProvider<RankCatalog>((ref) async {
  return ref.read(apiClientProvider).rankCatalog();
});
