import 'package:flutter/material.dart';

import '../data/models/chapter.dart';
import '../data/models/novel_item.dart';
import '../data/models/video_series.dart';
import '../features/detail/detail_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/video/video_detail_page.dart';
import '../features/video/video_player_page.dart';

/// 详情页入参。[preview] 是列表里点进来的卡片，用来在详情接口返回前先把
/// 封面/标题画出来，避免白屏。
class DetailArgs {
  const DetailArgs({required this.bookId, this.preview, this.heroTag});

  final String bookId;
  final NovelItem? preview;

  /// 发起点击的列表封面 Hero tag；详情页用同一个 tag 接住飞入动画。
  final String? heroTag;
}

/// 阅读页入参。[chapterId] 为空表示从第一章或上次进度开始。
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

/// 短剧详情入参。[preview] 同样用于接口返回前先画封面/标题。
class VideoDetailArgs {
  const VideoDetailArgs({required this.seriesId, this.preview, this.heroTag});

  final String seriesId;
  final VideoSeries? preview;

  /// 发起点击的列表封面 Hero tag；详情页用同一个 tag 接住飞入动画。
  final String? heroTag;
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
  });

  final String seriesTitle;
  final List<Chapter> episodes;
  final int index;
}

class AppRoutes {
  static const detail = '/detail';
  static const reader = '/reader';
  static const videoDetail = '/video/detail';
  static const videoPlay = '/video/play';
  static const settings = '/settings';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.settings:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const SettingsPage(),
        );
      case detail:
        final args = settings.arguments as DetailArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => DetailPage(
            bookId: args.bookId,
            preview: args.preview,
            heroTag: args.heroTag,
          ),
        );
      case reader:
        final args = settings.arguments as ReaderArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => ReaderPage(args: args),
        );
      case videoDetail:
        final args = settings.arguments as VideoDetailArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => VideoDetailPage(
            seriesId: args.seriesId,
            preview: args.preview,
            heroTag: args.heroTag,
          ),
        );
      case videoPlay:
        final args = settings.arguments as VideoPlayArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => VideoPlayerPage(args: args),
        );
      default:
        return null;
    }
  }
}
