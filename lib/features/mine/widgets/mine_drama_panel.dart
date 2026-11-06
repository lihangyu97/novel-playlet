import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/widgets/cover_hero.dart';
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
import 'panel_shell.dart';

/// 短剧面板：读本地收藏/观看记录，注入 [PanelShell] 的骨架（镜像版式）。
class MineDramaPanel extends ConsumerWidget {
  const MineDramaPanel({
    super.key,
    required this.bottomInset,
    required this.progress,
  });

  final double bottomInset;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDramaDataProvider);
    final data = async.value;
    final metrics = MineGridMetrics.of(context);
    return PanelShell<MineDramaData>(
      data: data,
      progress: progress,
      mirrored: true,
      bottomInset: bottomInset,
      title: '短剧',
      icon: Icons.theaters_rounded,
      stats: _statsOf(async, data),
      placeholder: async.hasError
          ? ErrorView(
              message: '读取短剧收藏失败，请重试',
              onRetry: () => ref.invalidate(mineDramaDataProvider),
            )
          : const LoadingView(label: '正在读取短剧数据…'),
      recentOf: (data) => Column(
        children: [
          const MineSectionHeader(title: '最近观看', mirrored: true),
          if (data.history.isEmpty)
            const SizedBox(
              height: 140,
              child: EmptyView(
                message: '还没有观看记录，去推荐页看看短剧',
                icon: Icons.history_rounded,
              ),
            )
          else
            MineRecentWatching(
              items: data.history,
              onOpen: (progress) => _resume(context, ref, progress),
            ),
        ],
      ),
      gridOf: (data) => Column(
        children: [
          MineSectionHeader(
            title: '我的收藏',
            mirrored: true,
            hint: data.collections.isEmpty ? null : '长按管理',
          ),
          MineDramaShelfGrid(
            items: data.collections,
            crossAxisCount: metrics.columns,
            itemWidth: metrics.itemWidth,
            itemHeight: metrics.itemHeight,
            spacing: MineGridMetrics.spacing,
            heroTagOf: (item) =>
                CoverHeroTag.video('mine-drama-shelf', item.id),
            onOpen: (item) => _openDetail(context, item),
            onLongPress: (item) => _showCollectionMenu(context, ref, item),
          ),
        ],
      ),
    );
  }

  String _statsOf(AsyncValue<MineDramaData> async, MineDramaData? data) {
    if (data != null) {
      return '最近观看 ${data.history.length} 条 · 收藏 ${data.collections.length} 部';
    }
    return async.hasError ? '本地短剧数据暂时读不出来' : '正在读取短剧数据…';
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error is ApiException ? error.message : '打开播放失败，请重试'),
        ),
      );
    }
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
