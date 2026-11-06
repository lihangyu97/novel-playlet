import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../mine/mine_providers.dart';

/// 某部短剧是否已收藏。
///
/// 依赖 [videoRevisionProvider]：详情页收藏/取消收藏后自动刷新按钮态。
final videoShelfStatusProvider = FutureProvider.family<bool, String>((
  ref,
  seriesId,
) async {
  ref.watch(videoRevisionProvider);
  final store = ref.watch(readingStoreProvider);
  return store.isVideoOnShelf(seriesId);
});

/// 某部短剧看到第几集；null = 还没看过。
final videoProgressProvider =
    FutureProvider.family<VideoWatchProgress?, String>((ref, seriesId) async {
      ref.watch(videoRevisionProvider);
      final store = ref.watch(readingStoreProvider);
      return store.videoProgress(seriesId);
    });
