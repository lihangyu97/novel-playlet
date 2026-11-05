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
import 'widgets/episode_picker.dart';

/// 短剧详情：与小说详情共用同一套版式（沉浸渐变 + 封面/标题/元信息 +
/// 简介/标签卡片），差异只在「选集」这个特殊模块。
///
/// 详情与选集是两个上游接口（`/series/{id}` 与 `/books/{id}/directory`），
/// 互不依赖所以并发拉；任一失败都落到整页重试——没有选集就无法播放，详情
/// 缺字段反而可以容忍（用列表带过来的 [preview] 兜底）。
///
/// 列表带 [preview] 进来时，封面/标题会**立刻**从 preview 画出来，不先进
/// Loading：这样 Hero 的目标在路由动画开始时就存在，封面能从列表卡片直接
/// 飞入详情，而不是等接口回来才突然出现。
class VideoDetailPage extends ConsumerStatefulWidget {
  const VideoDetailPage({
    super.key,
    required this.seriesId,
    this.preview,
    this.heroTag,
  });

  final String seriesId;
  final VideoSeries? preview;

  /// 封面 Hero tag（列表点进来时由 [VideoDetailArgs] 带下来）；null = 不飞入。
  final String? heroTag;

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
            return _buildContent(
              snapshot.data?.detail,
              snapshot.data?.episodes,
              error: snapshot.error,
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(
    VideoDetail? detail,
    List<Chapter>? episodes, {
    Object? error,
  }) {
    final preview = widget.preview;
    final title = detail != null && detail.title.isNotEmpty
        ? detail.title
        : (preview?.title ?? '短剧');
    // 和小说详情一致：封面固定用列表 preview，详情接口不换图，避免 Hero
    // 落位后图片再加载一次闪一下；列表没封面才用详情图。
    final cover = preview != null && preview.cover.isNotEmpty
        ? preview.cover
        : (detail?.cover ?? '');
    final intro = detail != null && detail.intro.isNotEmpty
        ? detail.intro
        : (preview?.intro ?? '');
    final count = detail != null && detail.episodeCount > 0
        ? detail.episodeCount
        : (episodes?.length ?? preview?.episodeCount ?? 0);
    // 「全 N 集」和播放量合并成一行；分类已经作为标签显示在下方简介卡里，
    // 不再出现在这行，避免重复。
    final subtitle = [
      if (count > 0) '全 $count 集',
      if (detail != null && detail.playCount > 0)
        '${_formatCount(detail.playCount)} 次播放',
    ].join(' · ');
    final ready = detail != null && episodes != null;

    return CustomScrollView(
      slivers: [
        // 背景只跟封面走、固定高度：Hero 目标从第一帧就存在，封面飞进来后
        // 直接成为背景；接口回来内容变高也不会牵动背景。
        SliverToBoxAdapter(
          child: DetailCoverBackdrop(
            cover: cover,
            heroTag: widget.heroTag,
          ),
        ),
        if (ready) ...[
          SliverToBoxAdapter(
            child: DetailFadeIn(
              child: DetailTitleSection(
                title: title,
                subtitle: subtitle,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: DetailFadeIn(
              delay: const Duration(milliseconds: 60),
              child: DetailIntroCard(intro: intro, tags: detail.categories),
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
            SliverToBoxAdapter(
              // 1000+ 集的剧不能整页平铺：36 集一个 tab，默认展开。
              child: DetailFadeIn(
                delay: const Duration(milliseconds: 120),
                child: EpisodePicker(
                  episodes: episodes,
                  initiallyExpanded: true,
                  onOpen: (index) => _openEpisode(detail, episodes, index),
                ),
              ),
            ),
        ] else if (error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView(
              message: error is ApiException ? error.message : '剧集加载失败，请重试',
              onRetry: _retry,
            ),
          ),
        // 加载阶段只保留封面背景：不再转圈，内容就绪后直接淡入。
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
