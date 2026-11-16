import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/app_section_header.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/states.dart';
import '../../app/widgets/top_glow.dart';
import '../../core/storage/library_records.dart';
import 'mine_providers.dart';
import 'widgets/media_manage_sheet.dart';
import 'widgets/mine_grid_metrics.dart';
import 'widgets/mine_header.dart';
import 'widgets/mine_history_list.dart';
import 'widgets/mine_library_grid.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

/// 我的：统一页头 + 「历史」+「收藏」两个区块。
///
/// 小说与短剧不再分 tab，而是**同一条时间线 / 同一个收藏夹**：历史按最近
/// 阅读（或观看）时间倒序混排，收藏按加入时间倒序混排，条目上挂彩色标签
/// 区分类型（绿=小说、橙=短剧）。
///
/// 页头（图标 + 「我的」 + 合并统计 + 缓存 / 设置）固定贴顶、不随内容滚动；
/// 顶部氛围渐变整页一套。
///
/// 页面根节点**不订阅任何数据 provider**：页头统计由 [_MineStats] 叶子自己
/// watch，阅读页落一次进度时只有「历史」那一块重建（CODE_REVIEW
/// P1-5）。两个区块各自订阅自己的通道，互不牵连。
class MinePage extends ConsumerWidget {
  const MinePage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表末尾多留这么多空白。
  final double bottomInset;

  /// 测试/无障碍定位用。
  static const historyKey = Key('mine-history');
  static const collectionKey = Key('mine-collection');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 渐变要盖到状态栏那一条（安全区不参与布局），否则顶部会留一条纯白。
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 150 + topInset,
            child: const TopGlow(spec: kMineTopGlow),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                MineHeader(
                  title: '我的',
                  icon: Icons.person_rounded,
                  stats: const _MineStats(),
                  onCache: () => context.pushAppRoute(const CacheCenterRoute()),
                  onSettings: () => context.pushAppRoute(const SettingsRoute()),
                ),
                Expanded(
                  child: CustomScrollView(
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _MineHistorySection(key: historyKey),
                      ),
                      SliverToBoxAdapter(
                        child: _MineCollectionSection(key: collectionKey),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: 28 + bottomInset),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _sectionHeader(String title) => AppSectionHeader(
  title: title,
  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
);

/// 数据没就绪时的统一占位（加载中 / 读取失败）。
Widget _sectionPlaceholder(Widget child) => SizedBox(height: 140, child: child);

const _readFailed = '读取本地数据失败，请重试';

/// 「历史」：读过的小说与看过的短剧混排，按最近一次阅读/观看倒序。
class _MineHistorySection extends ConsumerWidget {
  const _MineHistorySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineHistoryProvider);
    return Column(children: [_sectionHeader('历史'), _body(context, ref, async)]);
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<LibraryRecord>> async,
  ) {
    final items = async.value;
    if (items == null) {
      return _sectionPlaceholder(
        async.hasError
            ? ErrorView(
                message: _readFailed,
                onRetry: () => ref.invalidate(mineHistoryProvider),
              )
            : const LoadingView(label: '正在读取本地数据…'),
      );
    }
    if (items.isEmpty) {
      return _sectionPlaceholder(
        const EmptyView(message: '还没有阅读记录，去推荐页逛逛', icon: Icons.history_rounded),
      );
    }
    return MineHistoryList(
      items: items,
      onOpen: (item) => _openHistory(context, ref, item),
    );
  }

  void _openHistory(BuildContext context, WidgetRef ref, LibraryRecord item) {
    if (item.type.isPlaylet) {
      _resumeVideo(context, ref, item);
      return;
    }
    context.pushAppRoute(
      ReaderRoute(
        ReaderArgs(
          bookId: item.sourceId,
          bookTitle: item.title,
          cover: item.cover,
          chapterId: item.progressRef,
          chapterIndex: item.progressIndex,
          blockIndex: item.progressSub,
        ),
      ),
    );
  }

  /// 历史里的短剧点击续播：先拉分集列表，再直接进播放页对应集。
  Future<void> _resumeVideo(
    BuildContext context,
    WidgetRef ref,
    LibraryRecord item,
  ) async {
    try {
      final api = ref.read(apiClientProvider);
      final episodes = await api.videoEpisodes(item.sourceId);
      if (episodes.isEmpty) {
        throw ApiException('这部剧暂时没有可播放的集数');
      }
      if (!context.mounted) return;
      final index = item.progressIndex < episodes.length
          ? item.progressIndex
          : 0;
      context.pushAppRoute(
        VideoPlayRoute(
          VideoPlayArgs(
            seriesTitle: item.title,
            episodes: episodes,
            index: index,
            seriesId: item.sourceId,
            cover: item.cover,
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(context, apiErrorCopy(error, fallback: '打开播放失败，请重试'));
    }
  }
}

/// 「收藏」：小说与短剧混排，封面统一 3:4，左上角彩色标签区分类型。
class _MineCollectionSection extends ConsumerWidget {
  const _MineCollectionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineCollectionProvider);
    return Column(children: [_sectionHeader('收藏'), _body(context, ref, async)]);
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<LibraryRecord>> async,
  ) {
    final items = async.value;
    if (items == null) {
      return _sectionPlaceholder(
        async.hasError
            ? ErrorView(
                message: _readFailed,
                onRetry: () => ref.invalidate(mineCollectionProvider),
              )
            : const LoadingView(label: '正在读取本地数据…'),
      );
    }
    final metrics = MineGridMetrics.of(context);
    return MineLibraryGrid(
      items: items,
      crossAxisCount: metrics.columns,
      itemWidth: metrics.itemWidth,
      spacing: MineGridMetrics.spacing,
      onOpen: (item) => _openDetail(context, item),
      onLongPress: (item) => _manage(context, ref, item),
      heroTagOf: _heroTagOf,
    );
  }

  static String _heroTagOf(LibraryRecord item) => item.type.isPlaylet
      ? CoverHeroTag.video('mine-collection', item.sourceId)
      : CoverHeroTag.novel('mine-collection', item.sourceId);

  void _openDetail(BuildContext context, LibraryRecord item) {
    final heroTag = _heroTagOf(item);
    if (item.type.isPlaylet) {
      context.pushAppRoute(
        VideoDetailRoute(
          seriesId: item.sourceId,
          preview: VideoSeries(
            id: item.sourceId,
            title: item.title,
            cover: item.cover,
            intro: item.intro,
            episodeCount: item.episodeCount,
            colorDominate: item.colorDominate,
          ),
          heroTag: heroTag,
        ),
      );
      return;
    }
    context.pushAppRoute(
      DetailRoute(
        bookId: item.sourceId,
        preview: NovelItem(
          id: item.sourceId,
          title: item.title,
          cover: item.cover,
          author: item.author,
          colorDominate: item.colorDominate,
        ),
        heroTag: heroTag,
      ),
    );
  }

  Future<void> _manage(
    BuildContext context,
    WidgetRef ref,
    LibraryRecord item,
  ) {
    final store = ref.read(readingStoreProvider);
    final isPlaylet = item.type.isPlaylet;
    return showMediaManageSheet(
      context: context,
      title: item.title,
      removeLabel: isPlaylet ? '移出收藏' : '移出书架',
      openDetail: () => _openDetail(context, item),
      remove: () => isPlaylet
          ? store.removeVideoFromShelf(item.sourceId)
          : store.removeFromShelf(item.sourceId),
      removedMessage: isPlaylet
          ? '已取消收藏《${item.title}》'
          : '已把《${item.title}》移出书架',
    );
  }
}

/// 页头统计行：只订阅「历史条数 / 收藏条数」。
///
/// 单独做成 ConsumerWidget，[MinePage] 根节点自己不 watch 任何数据 provider：
/// 阅读进度落盘（历史变化）不该让固定页头之外的区块跟着重建。
class _MineStats extends ConsumerWidget {
  const _MineStats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(mineHistoryCountProvider);
    final collection = ref.watch(mineCollectionProvider);
    final historyCount = history.value;
    final collectionCount = collection.value?.length;
    final String text;
    if (historyCount != null && collectionCount != null) {
      text = '历史 $historyCount · 收藏 $collectionCount';
    } else if (history.hasError || collection.hasError) {
      text = '本地数据暂时读不出来';
    } else {
      text = '正在读取本地数据…';
    }
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
