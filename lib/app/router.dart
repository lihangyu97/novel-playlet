import 'package:flutter/material.dart';

import '../data/models/novel_item.dart';
import '../features/detail/detail_page.dart';
import '../features/reader/reader_page.dart';

/// 详情页入参。[preview] 是列表里点进来的卡片，用来在详情接口返回前先把
/// 封面/标题画出来，避免白屏。
class DetailArgs {
  const DetailArgs({required this.bookId, this.preview});

  final String bookId;
  final NovelItem? preview;
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

class AppRoutes {
  static const detail = '/detail';
  static const reader = '/reader';

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case detail:
        final args = settings.arguments as DetailArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => DetailPage(bookId: args.bookId, preview: args.preview),
        );
      case reader:
        final args = settings.arguments as ReaderArgs;
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => ReaderPage(args: args),
        );
      default:
        return null;
    }
  }
}
