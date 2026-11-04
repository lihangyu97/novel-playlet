import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/detail/detail_common.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/video_detail.dart';
import '../../data/models/video_series.dart';

/// 短剧详情：与小说详情共用同一套版式（沉浸渐变 + 封面/标题/元信息 +
/// 简介/标签卡片），差异只在「选集」这个特殊模块。
///
/// 详情与选集是两个上游接口（`/series/{id}` 与 `/books/{id}/directory`），
/// 互不依赖所以并发拉；任一失败都落到整页重试——没有选集就无法播放，详情
/// 缺字段反而可以容忍（用列表带过来的 [preview] 兜底）。
class VideoDetailPage extends ConsumerStatefulWidget {
  const VideoDetailPage({super.key, required this.seriesId, this.preview});

  final String seriesId;
  final VideoSeries? preview;

  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> {
  Future<({VideoDetail detail, List<Chapter> episodes})>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = ref.read(apiClientProvider);
    _future = () async {
      final results = await Future.wait<Object>([
        api.videoDetail(widget.seriesId),
        api.videoEpisodes(widget.seriesId),
      ]);
      return (
        detail: results[0] as VideoDetail,
        episodes: results[1] as List<Chapter>,
      );
    }();
  }

  void _retry() => setState(_load);

  void _openEpisode(VideoDetail detail, List<Chapter> episodes, int index) {
    Navigator.of(context).pushNamed(
      AppRoutes.videoPlay,
      arguments: VideoPlayArgs(
        seriesTitle: detail.title.isNotEmpty
            ? detail.title
            : (widget.preview?.title ?? '短剧'),
        episodes: episodes,
        index: index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.primary.withValues(alpha: 0.10),
              scheme.primary.withValues(alpha: 0),
            ],
            stops: const [0, 0.32],
          ),
        ),
        child: FutureBuilder<({VideoDetail detail, List<Chapter> episodes})>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LoadingView(label: '正在加载剧集');
            }
            if (snapshot.hasError || !snapshot.hasData) {
              final error = snapshot.error;
              return ErrorView(
                message: error is ApiException ? error.message : '剧集加载失败，请重试',
                onRetry: _retry,
              );
            }
            final data = snapshot.data!;
            return _buildContent(data.detail, data.episodes);
          },
        ),
      ),
    );
  }

  Widget _buildContent(VideoDetail detail, List<Chapter> episodes) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = detail.title.isNotEmpty
        ? detail.title
        : (widget.preview?.title ?? '短剧');
    final cover = detail.cover.isNotEmpty
        ? detail.cover
        : (widget.preview?.cover ?? '');
    final intro = detail.intro.isNotEmpty
        ? detail.intro
        : (widget.preview?.intro ?? '');
    final count = detail.episodeCount > 0
        ? detail.episodeCount
        : episodes.length;
    final meta = [
      if (detail.categories.isNotEmpty) detail.categories.join(' · '),
      if (detail.playCount > 0) '${_formatCount(detail.playCount)} 次播放',
    ].join(' · ');

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DetailCoverHeader(
            cover: cover,
            title: title,
            subtitle: count > 0 ? '全 $count 集' : '',
            meta: meta,
          ),
        ),
        SliverToBoxAdapter(
          child: DetailIntroCard(intro: intro, tags: detail.categories),
        ),
        SliverToBoxAdapter(
          child: DetailSectionHeader(
            title: '选集',
            trailing: Text(
              '共 ${episodes.length} 集',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (episodes.isEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 168,
              child: EmptyView(
                message: '这部剧暂时没有可播放的集数',
                icon: Icons.movie_outlined,
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              detailGutter,
              0,
              detailGutter,
              24,
            ),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                mainAxisExtent: 44,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final episode = episodes[index];
                return OutlinedButton(
                  onPressed: () => _openEpisode(detail, episodes, index),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    textStyle: theme.textTheme.bodySmall,
                  ),
                  child: Text(
                    episode.title.isNotEmpty
                        ? episode.title
                        : '第 ${index + 1} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }, childCount: episodes.length),
            ),
          ),
      ],
    );
  }
}

String _formatCount(int value) {
  if (value >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(1)} 亿';
  }
  if (value >= 10000) {
    return '${(value / 10000).toStringAsFixed(1)} 万';
  }
  return '$value';
}
