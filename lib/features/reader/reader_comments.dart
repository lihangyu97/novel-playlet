import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/chapter_ideas.dart';

/// 段评数据的取数 key：同一章不同正文版本要分开缓存。
class ChapterCommentsArgs {
  const ChapterCommentsArgs({
    required this.bookId,
    required this.chapterId,
    this.itemVersion = '',
  });

  final String bookId;
  final String chapterId;
  final String itemVersion;

  @override
  bool operator ==(Object other) =>
      other is ChapterCommentsArgs &&
      other.bookId == bookId &&
      other.chapterId == chapterId &&
      other.itemVersion == itemVersion;

  @override
  int get hashCode => Object.hash(bookId, chapterId, itemVersion);
}

/// 当前章的段评汇总（计数 + 评论 id）。
///
/// 段评是阅读页装饰：网络/解析失败一律返回 [ChapterIdeas.empty]，由 UI 决定
/// 隐藏气泡与入口；绝不把阅读页打成错误态。切章后旧结果会被 autoDispose 回收。
final chapterIdeasProvider = FutureProvider.autoDispose
    .family<ChapterIdeas, ChapterCommentsArgs>((ref, args) async {
      if (args.chapterId.isEmpty) return ChapterIdeas.empty;
      try {
        return await ref
            .read(apiClientProvider)
            .chapterIdeas(args.chapterId, itemVersion: args.itemVersion);
      } catch (_) {
        // 计数失败不值得打扰读者，也不能阻塞阅读。
        return ChapterIdeas.empty;
      }
    }, retry: (retryCount, error) => null);
