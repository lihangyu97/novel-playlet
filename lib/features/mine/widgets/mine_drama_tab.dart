import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/cover_hero.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../app/widgets/states.dart';
import '../../../core/storage/reading_store.dart';
import '../../../data/models/json_utils.dart';
import '../../../data/models/video_series.dart';
import '../mine_drama_providers.dart';
import 'media_manage_sheet.dart';
import 'mine_drama_shelf_grid.dart';
import 'mine_grid_metrics.dart';
import 'mine_header.dart';
import 'mine_recent_watching.dart';
import 'mine_tab_body.dart';

/// 「短剧」tab：收藏 + 最近观看。
///
/// 页头与 tabs 由 [MinePage] 固定贴顶；这里只读本地数据并注入 [MineTabBody]。
///
/// 收藏订阅 [mineDramaShelfProvider]，最近观看由 [_MineRecentWatchingSection]
/// 单独订阅 [mineDramaHistoryProvider]：播放页存观看进度时只重建最近观看，
/// 收藏网格（以及 tab 本身）不重建（CODE_REVIEW P1-5 的短剧侧同构修法）。
class MineDramaTab extends ConsumerWidget {
  const MineDramaTab({super.key, required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDramaShelfProvider);
    final collections = async.value;
    final metrics = MineGridMetrics.of(context);
    return MineTabBody(
      bottomInset: bottomInset,
      placeholder: async.hasError
          ? ErrorView(
              message: '读取短剧收藏失败，请重试',
              onRetry: () => ref.invalidate(mineDramaShelfProvider),
            )
          : const LoadingView(label: '正在读取短剧数据…'),
      recent: const _MineRecentWatchingSection(),
      grid: collections == null
          ? null
          : Column(
              children: [
                MineSectionHeader(
                  title: '我的收藏',
                  hint: collections.isEmpty ? null : '长按管理',
                ),
                MineDramaShelfGrid(
                  items: collections,
                  crossAxisCount: metrics.columns,
                  itemWidth: metrics.itemWidth,
                  spacing: MineGridMetrics.spacing,
                  coverAspect: kVideoCoverAspect,
                  heroTagOf: (item) =>
                      CoverHeroTag.video('mine-drama-shelf', item.id),
                  onOpen: (item) => _openDetail(context, item),
                  onLongPress: (item) =>
                      _showCollectionMenu(context, ref, item),
                ),
              ],
            ),
    );
  }

  void _openDetail(BuildContext context, VideoSeries item) {
    context.pushAppRoute(
      VideoDetailRoute(
        seriesId: item.id,
        preview: item,
        heroTag: CoverHeroTag.video('mine-drama-shelf', item.id),
      ),
    );
  }

  Future<void> _showCollectionMenu(
    BuildContext context,
    WidgetRef ref,
    VideoSeries item,
  ) {
    return showMediaManageSheet(
      context: context,
      title: item.title,
      removeLabel: '移出收藏',
      openDetail: () => _openDetail(context, item),
      remove: () =>
          ref.read(readingStoreProvider).removeVideoFromShelf(item.id),
      removedMessage: '已取消收藏《${item.title}》',
    );
  }
}

/// 最近观看：独立订阅观看进度通道，播放/换集时只有这一块重建。
class _MineRecentWatchingSection extends ConsumerWidget {
  const _MineRecentWatchingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(mineDramaHistoryProvider).value;
    if (history == null) return const SizedBox.shrink();
    return Column(
      children: [
        const MineSectionHeader(title: '最近观看'),
        if (history.isEmpty)
          const SizedBox(
            height: 140,
            child: EmptyView(
              message: '还没有观看记录，去推荐页看看短剧',
              icon: Icons.history_rounded,
            ),
          )
        else
          MineRecentWatching(
            items: history,
            onOpen: (progress) => _resume(context, ref, progress),
          ),
      ],
    );
  }

  /// 最近观看点击续播：先拉分集列表，再直接进播放页对应集。
  Future<void> _resume(
    BuildContext context,
    WidgetRef ref,
    VideoWatchProgress progress,
  ) async {
    try {
      final api = ref.read(apiClientProvider);
      final episodes = await api.videoEpisodes(progress.seriesId);
      if (episodes.isEmpty) {
        throw ApiException('这部剧暂时没有可播放的集数');
      }
      if (!context.mounted) return;
      final index = progress.episodeIndex < episodes.length
          ? progress.episodeIndex
          : 0;
      context.pushAppRoute(
        VideoPlayRoute(
          VideoPlayArgs(
            seriesTitle: progress.title,
            episodes: episodes,
            index: index,
            seriesId: progress.seriesId,
            cover: progress.cover,
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(context, apiErrorCopy(error, fallback: '打开播放失败，请重试'));
    }
  }
}
