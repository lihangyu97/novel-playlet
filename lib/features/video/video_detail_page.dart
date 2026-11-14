import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/router.dart';
import '../../app/widgets/detail/detail_common.dart';
import '../../app/widgets/states.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/book_comment.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/video_detail.dart';
import '../../data/models/video_series.dart';
import '../cache/offline_task.dart';
import '../cache/widgets/offline_download_button.dart';
import '../detail/detail_action_bar.dart';
import '../detail/detail_reviews_section.dart';
import 'video_comments_providers.dart';
import 'video_detail_providers.dart';
import 'video_library_providers.dart';
import 'widgets/episode_picker.dart';
import 'widgets/video_comments_sheet.dart';

/// 短剧详情：与小说详情共用同一套版式（沉浸渐变 + 封面/标题/元信息 +
/// 简介/标签卡片），差异只在「选集」这个特殊模块。
///
/// 页面只负责布局与导航：详情 + 选集在 `video_detail_providers.dart`
/// （与小说详情的 `detail_providers.dart` 对称），收藏态 / 观看进度在
/// `video_library_providers.dart`，都不在页面里手写状态。
///
/// 列表带 [preview] 进来时，封面/标题会**立刻**从 preview 画出来，不先进
/// Loading：这样 Hero 的目标在路由动画开始时就存在，封面能从列表卡片直接
/// 飞入详情，而不是等接口回来才突然出现。
class VideoDetailPage extends ConsumerWidget {
  const VideoDetailPage({
    super.key,
    required this.seriesId,
    this.preview,
    this.heroTag,
  });

  final String seriesId;
  final VideoSeries? preview;

  /// 封面 Hero tag（列表点进来时由 [VideoDetailRoute] 带下来）；null = 不飞入。
  final String? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundleAsync = ref.watch(videoDetailBundleProvider(seriesId));
    final shelfAsync = ref.watch(videoShelfStatusProvider(seriesId));
    final progressAsync = ref.watch(videoProgressProvider(seriesId));
    // 剧评是详情页的次要信息：失败时 provider 给 null，页面整块不插入。
    final commentsAsync = ref.watch(videoSeriesCommentsProvider(seriesId));

    // 用 .value 而非 when：刷新时保留上一份数据，页面不闪加载态。
    final bundle = bundleAsync.value;
    final detail = bundle?.detail;
    final episodes = bundle?.episodes;

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 三颗悬浮圆直接盖在正文上（与小说详情、首页悬浮底栏同一套做法），
      // 正文末尾自己留白见 `_buildContent`。
      extendBody: true,
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
        child: _buildContent(
          context,
          detail,
          episodes,
          reviews: commentsAsync.value,
          error: bundleAsync.error,
          onRetry: () => ref.invalidate(videoDetailBundleProvider(seriesId)),
        ),
      ),
      bottomNavigationBar: _buildActionBar(
        context,
        ref,
        detail: detail,
        episodes: episodes,
        progress: progressAsync.value,
        onShelf: shelfAsync.value ?? false,
        shelfBusy: shelfAsync.isLoading && !shelfAsync.hasValue,
      ),
    );
  }

  /// 底部悬浮操作栏：从左到右「收藏 / 缓存 / 播放」三颗圆（与小说详情的
  /// 收藏 / 缓存 / 阅读同一套布局）。
  Widget? _buildActionBar(
    BuildContext context,
    WidgetRef ref, {
    required VideoDetail? detail,
    required List<Chapter>? episodes,
    required VideoWatchProgress? progress,
    required bool onShelf,
    required bool shelfBusy,
  }) {
    if (detail == null && preview == null) return null;
    final count = episodes?.length ?? 0;
    final canPlay = detail != null && count > 0;
    final resumeIndex = progress == null
        ? 0
        : (progress.episodeIndex < count ? progress.episodeIndex : 0);
    final primaryLabel = !canPlay
        ? '加载中…'
        : progress == null
        ? '播放'
        : '继续观看 · 第 ${resumeIndex + 1} 集';
    return DetailActionBar(
      primaryLabel: primaryLabel,
      primaryIcon: Icons.play_arrow_rounded,
      onPrimary: canPlay
          ? () => _openEpisode(context, detail, episodes!, resumeIndex)
          : null,
      shelfLabel: onShelf ? '已收藏' : '收藏',
      shelfActive: onShelf,
      onShelf: detail == null || shelfBusy
          ? null
          : () => _toggleShelf(context, ref, detail),
      // 缓存整剧：选集未就绪时不给入口（按钮要完整集列表算缺口/进度）。
      offlineButton: episodes == null || episodes.isEmpty
          ? null
          : OfflineDownloadButton(
              kind: OfflineTaskKind.video,
              id: seriesId,
              title: _titleOf(detail),
              cover: _coverOf(detail),
              items: episodes,
            ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    VideoDetail? detail,
    List<Chapter>? episodes, {
    BookCommentPage? reviews,
    Object? error,
    required VoidCallback onRetry,
  }) {
    final preview = this.preview;
    final title = _titleOf(detail);
    // [_coverOf] 和小说详情一致：封面固定用列表 preview，详情接口不换图，
    // 避免 Hero 落位后图片再加载一次闪一下；列表没封面才用详情图。
    final cover = _coverOf(detail);
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
          child: DetailCoverBackdrop(cover: cover, heroTag: heroTag),
        ),
        if (ready) ...[
          SliverToBoxAdapter(
            child: DetailFadeIn(
              child: DetailTitleSection(
                title: title,
                subtitle: subtitle,
                extra: _buildScoreRow(context, detail),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: DetailFadeIn(
              delay: const Duration(milliseconds: 60),
              child: DetailIntroCard(intro: intro, tags: detail.categories),
            ),
          ),
          // 剧评：简介之后、选集之前（与小说详情的书评卡片同款位置）。
          // 请求失败或没有评论时 reviews 为 null/空，整块不占位——次要数据
          // 不制造错误态，也不留空白卡片。
          if (reviews != null && reviews.comments.isNotEmpty)
            SliverToBoxAdapter(
              child: DetailFadeIn(
                delay: const Duration(milliseconds: 90),
                child: DetailReviewsSection(
                  page: reviews,
                  title: '剧评',
                  // 短剧评论没有评分，不画空星。
                  showStars: false,
                  onOpenAll: () => showVideoCommentsSheet(
                    context,
                    seriesId: seriesId,
                    initialPage: reviews,
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
            SliverToBoxAdapter(
              // 1000+ 集的剧不能整页平铺：36 集一个 tab，默认展开。
              child: DetailFadeIn(
                delay: const Duration(milliseconds: 120),
                child: EpisodePicker(
                  episodes: episodes,
                  initiallyExpanded: true,
                  onOpen: (index) =>
                      _openEpisode(context, detail, episodes, index),
                ),
              ),
            ),
        ] else if (error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView(
              // 详情+选集失败文案：统一走 apiErrorCopy（kind 短句兜底）。
              message: apiErrorCopy(error, fallback: '剧集加载失败，请重试'),
              onRetry: onRetry,
            ),
          ),
        // 加载阶段只保留封面背景：不再转圈，内容就绪后直接淡入。
        // 内容最下方展示资源 ID：一键复制，反馈问题时方便报出。数据没回来前
        // 不渲染（否则会先出现在封面下面，等内容淡入后再被顶下去）；和内容
        // 一起淡入，延迟排在简介/选集之后。
        if (ready || error != null)
          SliverToBoxAdapter(
            child: DetailFadeIn(
              delay: const Duration(milliseconds: 180),
              child: DetailIdFooter(id: seriesId, label: '短剧 ID'),
            ),
          ),
        // 悬浮操作栏盖在正文上方（extendBody）：末尾留出它的高度，最后一行
        // 滚到底时才停在按钮上面，而不是永远被三颗圆挡住。
        if (detail != null || preview != null)
          SliverToBoxAdapter(
            child: SizedBox(height: DetailActionBar.totalHeight(context) + 8),
          ),
      ],
    );
  }

  /// 评分行（与小说详情的「星标 + 分数」同款）；未评分返回 null 不占位。
  Widget? _buildScoreRow(BuildContext context, VideoDetail? detail) {
    final raw = detail?.score.trim() ?? '';
    if (raw.isEmpty || raw == '0' || raw == '0.0') return null;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(Icons.star_rounded, size: 16, color: scheme.primary),
        const SizedBox(width: 3),
        Text(
          '$raw分',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// 详情页展示的封面/标题优先级（列表 preview 优先，避免接口回来后换图）。
  String _titleOf(VideoDetail? detail) =>
      detail != null && detail.title.isNotEmpty
      ? detail.title
      : (preview?.title ?? '短剧');

  String _coverOf(VideoDetail? detail) {
    final preview = this.preview;
    if (preview != null && preview.cover.isNotEmpty) return preview.cover;
    return detail?.cover ?? '';
  }

  void _openEpisode(
    BuildContext context,
    VideoDetail detail,
    List<Chapter> episodes,
    int index,
  ) {
    context.pushAppRoute(
      VideoPlayRoute(
        VideoPlayArgs(
          seriesTitle: _titleOf(detail),
          episodes: episodes,
          index: index,
          seriesId: seriesId,
          cover: _coverOf(detail),
        ),
      ),
    );
  }

  /// 收藏落盘用的卡片字段：详情字段更全时优先详情，缺字段用列表 preview 兜底
  /// （和书架的 [VideoSeries.toStorageJson] 保持一致）。
  VideoSeries _shelfItemOf(VideoDetail detail) => VideoSeries(
    id: seriesId,
    title: _titleOf(detail),
    cover: _coverOf(detail),
    intro: detail.intro.isNotEmpty ? detail.intro : (preview?.intro ?? ''),
    episodeCount: detail.episodeCount > 0
        ? detail.episodeCount
        : (preview?.episodeCount ?? 0),
  );

  Future<void> _toggleShelf(
    BuildContext context,
    WidgetRef ref,
    VideoDetail detail,
  ) async {
    try {
      final nowOnShelf = await ref
          .read(videoShelfStatusProvider(seriesId).notifier)
          .toggle(_shelfItemOf(detail));
      if (!context.mounted) return;
      showAppSnackBar(context, nowOnShelf ? '已收藏' : '已取消收藏');
    } catch (_) {
      // controller 已把按钮态回滚到操作前，这里只负责提示。
      if (!context.mounted) return;
      showAppSnackBar(context, '收藏操作失败，请重试');
    }
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
