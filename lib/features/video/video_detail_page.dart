import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/video_detail.dart';
import '../../data/models/video_series.dart';

/// 短剧详情：封面 + 简介 + 选集。
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

  void _openEpisode(
    VideoDetail detail,
    List<Chapter> episodes,
    int index,
  ) {
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.preview?.title ?? '短剧')),
      body: FutureBuilder<({VideoDetail detail, List<Chapter> episodes})>(
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

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NovelCover(url: cover, width: 104, height: 138, radius: 12),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (count > 0)
                        Text(
                          '全 $count 集',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (detail.categories.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final category in detail.categories.take(4))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  category,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (detail.playCount > 0) ...[
                        const SizedBox(height: 10),
                        Text(
                          '${_formatCount(detail.playCount)} 次播放',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (intro.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: _ExpandableIntro(text: intro),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
            child: Text(
              episodes.isEmpty ? '暂无选集' : '选集',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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

/// 简介折叠：默认 3 行，点「展开」看全文。
class _ExpandableIntro extends StatefulWidget {
  const _ExpandableIntro({required this.text});

  final String text;

  @override
  State<_ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<_ExpandableIntro> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 4),
          Text(
            _expanded ? '收起' : '展开',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
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
