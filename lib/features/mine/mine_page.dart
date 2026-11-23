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
import 'widgets/mine_all_sheet.dart';
import 'widgets/mine_grid_metrics.dart';
import 'widgets/mine_header.dart';
import 'widgets/mine_history_list.dart';
import 'widgets/mine_pin_card.dart';
import 'widgets/mine_library_grid.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';

/// 我的：统一页头 + 「在看」+「收藏」+「历史」三个区块。
///
/// 小说与短剧不再分 tab：在看按 pin 时间倒序、收藏按加入时间倒序、历史按
/// 最近阅读（或观看）时间倒序，三类都混排，条目上挂彩色标签区分类型
/// （绿=小说、橙=短剧）。
///
/// 页头（图标 + 「我的」 + 缓存 / 设置）固定贴顶、不随内容滚动；顶部氛围
/// 渐变整页一套。区块顺序固定为「在看 → 收藏 → 历史」。
///
/// 页面根节点**不订阅任何数据 provider**：三个区块各自 watch 自己的通道，
/// 阅读页落一次进度只重建「历史」，切换 pin 只重建「在看」，收藏变更只重建
/// 「收藏」（CODE_REVIEW P1-5）。
class MinePage extends ConsumerWidget {
  const MinePage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表末尾多留这么多空白。
  final double bottomInset;

  /// 测试/无障碍定位用。
  static const pinKey = Key('mine-pin');
  static const historyKey = Key('mine-history');
  static const collectionKey = Key('mine-collection');
  static const pinAllKey = Key('mine-pin-all');
  static const historyAllKey = Key('mine-history-all');
  static const collectionAllKey = Key('mine-collection-all');

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
                  onCache: () => context.pushAppRoute(const CacheCenterRoute()),
                  onSettings: () => context.pushAppRoute(const SettingsRoute()),
                ),
                Expanded(
                  child: CustomScrollView(
                    physics: const ClampingScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _MinePinSection(key: pinKey),
                      ),
                      SliverToBoxAdapter(
                        child: _MineCollectionSection(key: collectionKey),
                      ),
                      SliverToBoxAdapter(
                        child: _MineHistorySection(key: historyKey),
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

/// 数据没就绪时的统一占位（加载中 / 读取失败）。
Widget _sectionPlaceholder(Widget child) => SizedBox(height: 140, child: child);

const _readFailed = '读取本地数据失败，请重试';

/// 「在看」：pin 过的内容排在页面最上面，横向一排卡片，可左右滑。
///
/// 没有 pin 时整块隐藏；加载中/失败也不占位（历史与收藏各自有错误态）。
class _MinePinSection extends ConsumerWidget {
  const _MinePinSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(minePinsProvider).value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        _MineSectionHeader(
          title: '在看',
          count: items.length,
          allKey: MinePage.pinAllKey,
          onShowAll: () => showMineAllSheet(
            context: context,
            scope: MineAllScope.pin,
            onOpen: (item) => openLibraryRecord(context, ref, item),
          ),
        ),
        SizedBox(
          height: MinePinCard.heightFor(context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) => MinePinCard(
              item: items[index],
              onTap: () => openLibraryRecord(context, ref, items[index]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「历史」：读过的小说与看过的短剧混排，按最近一次阅读/观看倒序。
class _MineHistorySection extends ConsumerWidget {
  const _MineHistorySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineHistoryProvider);
    final count = ref.watch(mineHistoryCountProvider).value;
    return Column(
      children: [
        _MineSectionHeader(
          title: '历史',
          count: count,
          allKey: MinePage.historyAllKey,
          onShowAll: () => showMineAllSheet(
            context: context,
            scope: MineAllScope.history,
            onOpen: (item) => openLibraryRecord(context, ref, item),
          ),
        ),
        _body(context, ref, async),
      ],
    );
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
      onOpen: (item) => openLibraryRecord(context, ref, item),
    );
  }
}

/// 打开一条本地记录：小说进阅读页续读，短剧拉分集后续播。
///
/// 「在看」「历史」和全量弹窗都走这里，避免续读逻辑各写一份。
Future<void> openLibraryRecord(
  BuildContext context,
  WidgetRef ref,
  LibraryRecord item,
) async {
  if (!item.type.isPlaylet) {
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
    return;
  }
  await _resumeVideo(context, ref, item);
}

/// 短剧点击续播：先拉分集列表，再直接进播放页对应集。
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
    final index = item.progressIndex < episodes.length ? item.progressIndex : 0;
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

/// 「收藏」：小说与短剧混排，封面统一 3:4，左上角彩色标签区分类型。
class _MineCollectionSection extends ConsumerWidget {
  const _MineCollectionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineCollectionPreviewProvider);
    final count = ref.watch(mineCollectionCountProvider).value;
    return Column(
      children: [
        _MineSectionHeader(
          title: '收藏',
          count: count,
          allKey: MinePage.collectionAllKey,
          onShowAll: () => showMineAllSheet(
            context: context,
            scope: MineAllScope.collection,
            onOpen: (item) => _openDetail(context, item),
          ),
        ),
        _body(context, ref, async),
      ],
    );
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
                onRetry: () => ref.invalidate(mineCollectionPreviewProvider),
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

/// 区块标题：左侧标题，右侧「N 条 + 全部 ›」。
///
/// 条数由区块自己 watch 计数 provider；[onShowAll] 只在有条目时出现，
/// 没条目时右侧只留 0 条，和空态文案对应。
class _MineSectionHeader extends StatelessWidget {
  const _MineSectionHeader({
    required this.title,
    required this.count,
    required this.allKey,
    required this.onShowAll,
  });

  final String title;
  final int? count;
  final Key allKey;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = count;
    return AppSectionHeader(
      title: title,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      titleSuffix: total == null
          ? null
          : Text(
              '$total 条',
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      trailing: total == null || total == 0
          ? null
          : Tooltip(
              message: '查看全部$title',
              child: TextButton(
                key: allKey,
                onPressed: onShowAll,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.primary,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('全部', style: theme.textTheme.bodySmall),
                    const Icon(Icons.chevron_right_rounded, size: 16),
                  ],
                ),
              ),
            ),
    );
  }
}
