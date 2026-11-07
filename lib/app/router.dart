import 'package:flutter/material.dart';

import '../data/models/chapter.dart';
import '../data/models/novel_item.dart';
import '../data/models/video_series.dart';
import '../features/cache/cache_center_page.dart';
import '../features/detail/detail_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/video/video_detail_page.dart';
import '../features/video/video_player_page.dart';

/// 类型化路由：路由对象自己携带强类型参数，并负责构造对应的 [Route]。
///
/// 取代原来的字符串路由 + `onGenerateRoute` 里的 `arguments as XxxArgs`：
/// 参数传错会在编译期报错，而不是等到运行期才崩。页面里用
/// [BuildContext.pushAppRoute] 发起跳转：
///
/// ```dart
/// context.pushAppRoute(DetailRoute(bookId: id, preview: item));
/// ```
sealed class AppRoute<T> {
  const AppRoute();

  /// 构造承载目标页面、参数已强类型化的 [Route]。
  Route<T> toRoute();
}

/// 极简跳转辅助，省掉每处 `Navigator.of(context).push(...toRoute())` 的样板。
extension AppRouteContext on BuildContext {
  Future<T?> pushAppRoute<T>(AppRoute<T> route) =>
      Navigator.of(this).push(route.toRoute());
}

/// 小说详情页。[preview] 是列表里点进来的卡片，用来在详情接口返回前先把
/// 封面/标题画出来，避免白屏。
final class DetailRoute extends AppRoute<void> {
  const DetailRoute({required this.bookId, this.preview, this.heroTag});

  final String bookId;
  final NovelItem? preview;

  /// 发起点击的列表封面 Hero tag；详情页用同一个 tag 接住飞入动画。
  final String? heroTag;

  @override
  Route<void> toRoute() => MaterialPageRoute<void>(
    builder: (_) =>
        DetailPage(bookId: bookId, preview: preview, heroTag: heroTag),
  );
}

/// 缓存中心页（「我的」右下角悬浮缓存按钮 / 详情页「缓存中·已缓存」进入）。
///
/// 兼下载队列展示与离线缓存管理：暂停/继续/取消排队、单条删除、按区清空都
/// 在这里，不再有单独的管理页。
final class CacheCenterRoute extends AppRoute<void> {
  const CacheCenterRoute();

  @override
  Route<void> toRoute() =>
      MaterialPageRoute<void>(builder: (_) => const CacheCenterPage());
}

/// 短剧详情页。[preview] 同样用于接口返回前先画封面/标题。
final class VideoDetailRoute extends AppRoute<void> {
  const VideoDetailRoute({required this.seriesId, this.preview, this.heroTag});

  final String seriesId;
  final VideoSeries? preview;

  /// 发起点击的列表封面 Hero tag；详情页用同一个 tag 接住飞入动画。
  final String? heroTag;

  @override
  Route<void> toRoute() => MaterialPageRoute<void>(
    builder: (_) =>
        VideoDetailPage(seriesId: seriesId, preview: preview, heroTag: heroTag),
  );
}

/// 阅读页入参。[chapterId] 为空表示从第一章或上次进度开始。
///
/// 它仍是阅读页自己的入参（[ReaderRoute] 只是把它包成路由），不是路由标识。
class ReaderArgs {
  const ReaderArgs({
    required this.bookId,
    this.bookTitle = '',
    this.cover = '',
    this.chapterId,
    this.chapterIndex,
    this.blockIndex,
  });

  final String bookId;
  final String bookTitle;
  final String cover;
  final String? chapterId;
  final int? chapterIndex;

  /// 目标章内的段落落点（当前页首段下标）。详情页「继续阅读」/「我的」最近
  /// 阅读会带上它，让页级进度真正生效；显式点某一章时为 null（从页首开始）。
  final int? blockIndex;
}

/// 阅读页路由。
final class ReaderRoute extends AppRoute<void> {
  const ReaderRoute(this.args);

  final ReaderArgs args;

  @override
  Route<void> toRoute() =>
      MaterialPageRoute<void>(builder: (_) => ReaderPage(args: args));
}

/// 播放页入参：整份选集 + 起播下标。
///
/// 选集由详情页一次拉齐后传入：播放页换集只换 URL，不再回源目录，连续点
/// 下一集也不会多打目录请求。
class VideoPlayArgs {
  const VideoPlayArgs({
    required this.seriesTitle,
    required this.episodes,
    required this.index,
    this.seriesId = '',
    this.cover = '',
  });

  final String seriesTitle;
  final List<Chapter> episodes;
  final int index;

  /// 剧集 id / 封面：播放页用它记录「看到第几集」，我的页最近观看要展示。
  /// 从详情页进来时一定带；老调用方不传也不影响播放。
  final String seriesId;
  final String cover;
}

/// 播放页路由。
final class VideoPlayRoute extends AppRoute<void> {
  const VideoPlayRoute(this.args);

  final VideoPlayArgs args;

  @override
  Route<void> toRoute() =>
      MaterialPageRoute<void>(builder: (_) => VideoPlayerPage(args: args));
}

/// 设置页路由：无参数。
final class SettingsRoute extends AppRoute<void> {
  const SettingsRoute();

  @override
  Route<void> toRoute() =>
      MaterialPageRoute<void>(builder: (_) => const SettingsPage());
}
