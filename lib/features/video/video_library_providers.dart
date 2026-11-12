import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/video_series.dart';
import '../mine/mine_providers.dart';

/// 某部短剧是否已收藏。
///
/// 用 AsyncNotifier 而不是 FutureProvider：收藏/取消要「先回显、后落盘」，
/// 按钮不能等 SharedPreferences 写完才变（与小说详情的 detailShelfProvider
/// 同款）。
///
/// 这里刻意不再 watch [videoRevisionProvider]：收藏态只由本 controller 的
/// [VideoShelfController.toggle] 写入，播放页每换一集都会 bump 那个计数，
/// 没必要为此把收藏表整个重读一遍（架构评审 P0-3）。离开详情页后
/// autoDispose 回收，下次进入重新读一次。
final videoShelfStatusProvider = AsyncNotifierProvider.autoDispose
    .family<VideoShelfController, bool, String>(VideoShelfController.new);

class VideoShelfController extends AsyncNotifier<bool> {
  VideoShelfController(this.seriesId);

  final String seriesId;

  @override
  Future<bool> build() {
    final store = ref.watch(readingStoreProvider);
    return store.isVideoOnShelf(seriesId);
  }

  /// 只加不移（播放页「收藏」用）：已收藏直接返回，不写盘也不报错。
  ///
  /// 与阅读页「加入书架」同一语义；取消收藏走「我的 → 收藏」长按管理，
  /// 播放页不做取消，避免看剧时误触把收藏删掉。
  Future<void> add(VideoSeries item) async {
    if (state.value ?? false) return;
    state = const AsyncData(true);
    try {
      await ref.read(readingStoreProvider).addVideoToShelf(item);
    } catch (_) {
      if (ref.mounted) state = const AsyncData(false);
      rethrow;
    }
  }

  /// 切换收藏，返回切换后的状态。落盘失败会回滚并重新抛出，由页面提示。
  Future<bool> toggle(VideoSeries item) async {
    final store = ref.read(readingStoreProvider);
    final wasOnShelf = state.value ?? false;
    // 先回显再落盘；写盘期间用户若已退出详情页（provider 被 autoDispose
    // 回收），就不要再碰 state 了。
    state = AsyncData(!wasOnShelf);
    try {
      if (wasOnShelf) {
        await store.removeVideoFromShelf(seriesId);
      } else {
        await store.addVideoToShelf(item);
      }
      return !wasOnShelf;
    } catch (_) {
      if (ref.mounted) state = AsyncData(wasOnShelf);
      rethrow;
    }
  }
}

/// 某部短剧看到第几集；null = 还没看过。
///
/// 依赖 [videoRevisionProvider]：播放页存进度（换集/退出）后自动刷新
/// 「继续观看 · 第N集」。autoDispose 同 [videoShelfStatusProvider]：详情页
/// 关掉后不再驻留，也不再因为别的剧写进度而白读一次本地进度。
final videoProgressProvider = FutureProvider.autoDispose
    .family<VideoWatchProgress?, String>((ref, seriesId) async {
      ref.watch(videoRevisionProvider);
      final store = ref.watch(readingStoreProvider);
      return store.videoProgress(seriesId);
    });
