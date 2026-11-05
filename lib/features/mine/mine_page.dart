import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../../data/models/video_series.dart';
import 'mine_drama_providers.dart';
import 'mine_providers.dart';
import 'widgets/mine_drama_shelf_grid.dart';
import 'widgets/mine_recent_reading.dart';
import 'widgets/mine_recent_watching.dart';
import 'widgets/mine_shelf_grid.dart';

/// 面板切换的时间轴：最近阅读/观看块 0ms 起步、标题块 100ms、书架/收藏块
/// 200ms，每块自己滑 300ms，所以总时间轴 500ms（见 [_StaggeredBlock] 的
/// 窗口换算）。
const _panelTimeline = Duration(milliseconds: 500);

/// 每块在时间轴上占 60%（300ms），相邻块错开 20%（100ms）。
const _panelBlockWindow = 0.6;
const _panelBlockDelay = 0.2;

/// 横滑甩过这个速度就直接翻页，不再看拖拽比例。
const _panelSwipeVelocity = 300.0;

/// 我的：小说 / 短剧 两块面板，右下角悬浮按钮或左右滑动切换。
///
/// 两个面板是同一套版式的镜像：小说的标题/图标在左、设置按钮在右；短剧反过来
/// （标题/图标在右、设置在左）。切换时不是整页一起平移，而是分三块穿插着
/// 滑出/滑入（最近阅读/观看 0ms、标题 100ms、书架/收藏 200ms 延迟）。
///
/// 小说侧数据全部在本地（书架 + 阅读进度）；短剧侧的收藏/观看记录还没做，
/// 先用 [mineDramaDataProvider] 的空列表占位，页面结构与交互按最终形态搭好。
class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表末尾多留这么多空白。
  final double bottomInset;

  /// 测试/无障碍定位用（两个面板 + 切换按钮）。
  static const novelPanelKey = Key('mine-panel-novel');
  static const dramaPanelKey = Key('mine-panel-drama');
  static const switchButtonKey = Key('mine-panel-switch');

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage>
    with SingleTickerProviderStateMixin {
  /// 0 = 小说，1 = 短剧；拖拽过程中只有松手才更新它。
  int _panel = 0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _panelTimeline,
    value: 0,
  );

  bool get _showingDrama => _panel == 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).pushNamed(AppRoutes.settings);
  }

  void _togglePanel() => _animateTo(_panel == 1 ? 0 : 1);

  /// 收尾到某一侧：按剩余进度折算时长，保证分块延迟的节奏不被打乱。
  void _animateTo(int target) {
    final remaining = (target - _controller.value).abs();
    if (target != _panel) setState(() => _panel = target);
    if (remaining < 0.001) return;
    final millis = math.max(
      120,
      (_panelTimeline.inMilliseconds * remaining).round(),
    );
    _controller.animateTo(
      target.toDouble(),
      duration: Duration(milliseconds: millis),
      curve: Curves.easeOutCubic,
    );
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _controller.stop();
  }

  /// 直接拖拽：手指移动多少，时间轴就走多少，分块窗口让它自然错开。
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _controller.value = (_controller.value - details.delta.dx / width).clamp(
      0.0,
      1.0,
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() > _panelSwipeVelocity) {
      // 往左甩 = 看下一块（短剧），往右甩 = 回小说。
      _animateTo(velocity < 0 ? 1 : 0);
      return;
    }
    _animateTo(_controller.value >= 0.5 ? 1 : 0);
  }

  /// 只有停在某一端时才允许该面板接收滚动/点击；拖拽和动画过程中两边都锁住，
  /// 避免滑动一半时误滚某个列表。
  bool _isSettledAt(int index) {
    if (_controller.isAnimating) return false;
    return index == 0 ? _controller.value <= 0.001 : _controller.value >= 0.999;
  }

  @override
  Widget build(BuildContext context) {
    // 预取短剧侧数据：如果等切换时才第一次 watch，滑入过程中会闪一下
    // 「正在读取…」。小说侧也是进页面就读，两边保持一致。
    ref.watch(mineDramaDataProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              child: Stack(
                children: [
                  _panelSurface(
                    index: 0,
                    child: _NovelPanel(
                      key: MinePage.novelPanelKey,
                      bottomInset: widget.bottomInset,
                      progress: _controller,
                    ),
                  ),
                  _panelSurface(
                    index: 1,
                    child: _DramaPanel(
                      key: MinePage.dramaPanelKey,
                      bottomInset: widget.bottomInset,
                      progress: _controller,
                    ),
                  ),
                ],
              ),
            ),
            // 唯一一个设置按钮：小说面板时在右、短剧面板时在左，切换过程中
            // 跟着 _controller 在屏幕内左右移动（不会被滑出屏幕）。
            Positioned(
              top: 20,
              left: 16,
              right: 16,
              height: 40,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Align(
                    alignment: Alignment(1 - 2 * _controller.value, 0),
                    child: child,
                  );
                },
                child: IconButton(
                  onPressed: _openSettings,
                  tooltip: '设置',
                  visualDensity: VisualDensity.compact,
                  iconSize: 22,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
            ),
            // 右下角悬浮切换按钮：贴在悬浮底栏上方，不遮胶囊。
            Positioned(
              right: 16,
              bottom: widget.bottomInset + 16,
              child: _PanelSwitchButton(
                key: MinePage.switchButtonKey,
                showingDrama: _showingDrama,
                onTap: _togglePanel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelSurface({required int index, required Widget child}) {
    return AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, child) {
        final settled = _isSettledAt(index);
        return IgnorePointer(
          ignoring: !settled,
          child: ExcludeSemantics(excluding: !settled, child: child),
        );
      },
    );
  }
}

/// 单块内容的阶梯位移动画。
///
/// 时间轴 0..1 表示「小说 → 短剧」的进度：
/// - 第 [index] 块从 `index * 0.2` 开始、耗时 `0.6`（= 300ms）；
/// - 最近块 index=0（0ms）、标题 index=1（100ms）、书架/收藏 index=2（200ms）；
/// - 出场的块往左滑出，入场的块从右侧滑入。
class _StaggeredBlock extends StatelessWidget {
  const _StaggeredBlock({
    required this.progress,
    required this.index,
    required this.incoming,
    required this.child,
  });

  final Animation<double> progress;
  final int index;
  final bool incoming;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final start = index * _panelBlockDelay;
        final value = ((progress.value - start) / _panelBlockWindow).clamp(
          0.0,
          1.0,
        );
        final dx = incoming ? width * (1 - value) : -width * value;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );
  }
}

/// 悬浮切换按钮：当前看小说时显示短剧图标（点它去短剧），反之亦然。
class _PanelSwitchButton extends StatelessWidget {
  const _PanelSwitchButton({
    super.key,
    required this.showingDrama,
    required this.onTap,
  });

  final bool showingDrama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = showingDrama
        ? Icons.auto_stories_rounded
        : Icons.theaters_rounded;
    final label = showingDrama ? '看小说' : '看短剧';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: scheme.primary,
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: Colors.black38,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: 24,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小说面板
// ---------------------------------------------------------------------------

class _NovelPanel extends ConsumerWidget {
  const _NovelPanel({
    super.key,
    required this.bottomInset,
    required this.progress,
  });

  final double bottomInset;
  final Animation<double> progress;

  static const _gutter = 16.0;
  static const _gridSpacing = 12.0;

  /// 卡片目标宽度：手机 3 列、iPad 自动增列，避免宽屏上封面被拉得过大。
  static const _maxCardWidth = 128.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDataProvider);
    final data = async.value;
    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _StaggeredBlock(
            progress: progress,
            // 顶栏第二拍入场（最近阅读先走）。
            index: 1,
            incoming: false,
            child: _MineHeader(
              title: '小说',
              icon: Icons.auto_stories_rounded,
              stats: _statsOf(async, data),
            ),
          ),
        ),
        if (data != null) ...[
          if (data.recent.isNotEmpty)
            SliverToBoxAdapter(
              child: _StaggeredBlock(
                progress: progress,
                // 最近阅读 0 延迟，最先动。
                index: 0,
                incoming: false,
                child: Column(
                  children: [
                    const _SectionHeader(title: '最近阅读'),
                    MineRecentReading(
                      items: data.recent,
                      onOpen: (item) => _openReader(context, item),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _StaggeredBlock(
              progress: progress,
              index: 2,
              incoming: false,
              child: Column(
                children: [
                  _SectionHeader(
                    title: '我的书架',
                    hint: data.shelf.isEmpty ? null : '长按管理',
                  ),
                  MineShelfGrid(
                    shelf: data.shelf,
                    crossAxisCount: _columnsOf(context),
                    itemWidth: _itemWidthOf(context),
                    itemHeight: _itemHeightOf(context),
                    spacing: _gridSpacing,
                    heroTagOf: (item) =>
                        CoverHeroTag.novel('mine-shelf', item.id),
                    onOpen: (item) => _openDetail(context, item),
                    onLongPress: (item) => _showShelfMenu(context, ref, item),
                  ),
                ],
              ),
            ),
          ),
        ] else
          SliverToBoxAdapter(
            child: _StaggeredBlock(
              progress: progress,
              index: 0,
              incoming: false,
              child: SizedBox(
                height: 220,
                child: async.hasError
                    ? ErrorView(
                        message: '读取本地书架失败，请重试',
                        onRetry: () => ref.invalidate(mineDataProvider),
                      )
                    : const LoadingView(label: '正在读取书架…'),
              ),
            ),
          ),
        // 存储/清缓存入口在「设置」页；这里只留书架与最近阅读。
        SliverToBoxAdapter(child: SizedBox(height: 28 + bottomInset)),
      ],
    );
  }

  String _statsOf(AsyncValue<MineData> async, MineData? data) {
    if (data != null) {
      return '最近阅读 ${data.recent.length} 本 · 书架 ${data.shelf.length} 本';
    }
    return async.hasError ? '本地书架暂时读不出来' : '正在读取书架…';
  }

  double _availableWidth(BuildContext context) =>
      math.max(0.0, MediaQuery.sizeOf(context).width - _gutter * 2);

  int _columnsOf(BuildContext context) => math.max(
    2,
    math.min(6, (_availableWidth(context) / _maxCardWidth).ceil()),
  );

  double _itemWidthOf(BuildContext context) {
    final columns = _columnsOf(context);
    return math.max(
      0.0,
      (_availableWidth(context) - _gridSpacing * (columns - 1)) / columns,
    );
  }

  /// 与 NovelGridCard 的内部排版对齐（封面 kCoverAspect 比例 + 标题两行 +
  /// 作者一行），再按系统字体缩放留出高度，避免网格单元格比卡片矮造成溢出。
  double _itemHeightOf(BuildContext context) {
    final itemWidth = _itemWidthOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return itemWidth * kCoverAspect +
        8 +
        textScaler.scale(14) * 1.25 * 2 +
        3 +
        textScaler.scale(12) * 1.35 +
        6;
  }

  void _openDetail(BuildContext context, NovelItem item) {
    Navigator.of(context).pushNamed(
      AppRoutes.detail,
      arguments: DetailArgs(
        bookId: item.id,
        preview: item,
        heroTag: CoverHeroTag.novel('mine-shelf', item.id),
      ),
    );
  }

  void _openReader(BuildContext context, ReadingProgress progress) {
    Navigator.of(context).pushNamed(
      AppRoutes.reader,
      arguments: ReaderArgs(
        bookId: progress.bookId,
        bookTitle: progress.bookTitle,
        cover: progress.cover,
        chapterId: progress.chapterId,
        chapterIndex: progress.chapterIndex,
        blockIndex: progress.blockIndex,
      ),
    );
  }

  Future<void> _showShelfMenu(
    BuildContext context,
    WidgetRef ref,
    NovelItem item,
  ) async {
    final action = await showModalBottomSheet<_ShelfMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('查看详情'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_ShelfMenuAction.openDetail),
              ),
              ListTile(
                leading: Icon(
                  Icons.bookmark_remove_outlined,
                  color: scheme.error,
                ),
                title: Text('移出书架', style: TextStyle(color: scheme.error)),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_ShelfMenuAction.remove),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _ShelfMenuAction.openDetail:
        _openDetail(context, item);
      case _ShelfMenuAction.remove:
        final store = ref.read(readingStoreProvider);
        await store.removeFromShelf(item.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已把《${item.title}》移出书架')));
    }
  }
}

enum _ShelfMenuAction { openDetail, remove }

// ---------------------------------------------------------------------------
// 短剧面板
// ---------------------------------------------------------------------------

class _DramaPanel extends ConsumerWidget {
  const _DramaPanel({
    super.key,
    required this.bottomInset,
    required this.progress,
  });

  final double bottomInset;
  final Animation<double> progress;

  static const _gridSpacing = 12.0;
  static const _maxCardWidth = 128.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDramaDataProvider);
    final data = async.value;
    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _StaggeredBlock(
            progress: progress,
            // 顶栏第二拍入场（最近观看先走）。
            index: 1,
            incoming: true,
            child: _MineHeader(
              title: '短剧',
              icon: Icons.theaters_rounded,
              stats: _statsOf(async, data),
              mirrored: true,
            ),
          ),
        ),
        if (data != null) ...[
          SliverToBoxAdapter(
            child: _StaggeredBlock(
              progress: progress,
              // 最近观看 0 延迟，最先动。
              index: 0,
              incoming: true,
              child: Column(
                children: [
                  const _SectionHeader(title: '最近观看', mirrored: true),
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
            ),
          ),
          SliverToBoxAdapter(
            child: _StaggeredBlock(
              progress: progress,
              index: 2,
              incoming: true,
              child: Column(
                children: [
                  _SectionHeader(
                    title: '我的收藏',
                    mirrored: true,
                    hint: data.collections.isEmpty ? null : '长按管理',
                  ),
                  MineDramaShelfGrid(
                    items: data.collections,
                    crossAxisCount: _columnsOf(context),
                    itemWidth: _itemWidthOf(context),
                    itemHeight: _itemHeightOf(context),
                    spacing: _gridSpacing,
                    heroTagOf: (item) =>
                        CoverHeroTag.video('mine-drama-shelf', item.id),
                    onOpen: (item) => _openDetail(context, item),
                    onLongPress: (item) =>
                        _showCollectionMenu(context, ref, item),
                  ),
                ],
              ),
            ),
          ),
        ] else
          SliverToBoxAdapter(
            child: _StaggeredBlock(
              progress: progress,
              index: 0,
              incoming: true,
              child: SizedBox(
                height: 220,
                child: async.hasError
                    ? ErrorView(
                        message: '读取短剧收藏失败，请重试',
                        onRetry: () => ref.invalidate(mineDramaDataProvider),
                      )
                    : const LoadingView(label: '正在读取短剧数据…'),
              ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: 28 + bottomInset)),
      ],
    );
  }

  String _statsOf(AsyncValue<MineDramaData> async, MineDramaData? data) {
    if (data != null) {
      return '最近观看 ${data.history.length} 条 · 收藏 ${data.collections.length} 部';
    }
    return async.hasError ? '本地短剧数据暂时读不出来' : '正在读取短剧数据…';
  }

  double _availableWidth(BuildContext context) =>
      math.max(0.0, MediaQuery.sizeOf(context).width - 32);

  int _columnsOf(BuildContext context) => math.max(
    2,
    math.min(6, (_availableWidth(context) / _maxCardWidth).ceil()),
  );

  double _itemWidthOf(BuildContext context) {
    final columns = _columnsOf(context);
    return math.max(
      0.0,
      (_availableWidth(context) - _gridSpacing * (columns - 1)) / columns,
    );
  }

  /// 与 VideoCard 的内部排版对齐（封面 kCoverAspect + 标题两行 + 集数一行）。
  double _itemHeightOf(BuildContext context) {
    final itemWidth = _itemWidthOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return itemWidth * kCoverAspect +
        8 +
        textScaler.scale(14) * 1.25 * 2 +
        3 +
        textScaler.scale(12) * 1.35 +
        6;
  }

  void _openDetail(BuildContext context, VideoSeries item) {
    Navigator.of(context).pushNamed(
      AppRoutes.videoDetail,
      arguments: VideoDetailArgs(
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
      Navigator.of(context).pushNamed(
        AppRoutes.videoPlay,
        arguments: VideoPlayArgs(
          seriesTitle: progress.title,
          episodes: episodes,
          index: index,
          seriesId: progress.seriesId,
          cover: progress.cover,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is ApiException ? error.message : '打开播放失败，请重试',
          ),
        ),
      );
    }
  }

  Future<void> _showCollectionMenu(
    BuildContext context,
    WidgetRef ref,
    VideoSeries item,
  ) async {
    final action = await showModalBottomSheet<_ShelfMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final scheme = theme.colorScheme;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('查看详情'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_ShelfMenuAction.openDetail),
              ),
              ListTile(
                leading: Icon(
                  Icons.bookmark_remove_outlined,
                  color: scheme.error,
                ),
                title: Text('移出收藏', style: TextStyle(color: scheme.error)),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_ShelfMenuAction.remove),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _ShelfMenuAction.openDetail:
        _openDetail(context, item);
      case _ShelfMenuAction.remove:
        final store = ref.read(readingStoreProvider);
        await store.removeVideoFromShelf(item.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已取消收藏《${item.title}》')),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// 共用页头 / 区块标题
// ---------------------------------------------------------------------------

/// 页头：标题 + 图标 + 一行统计 + 设置入口。
///
/// [mirrored] 为 true 时整行左右镜像（短剧）：设置按钮在左、标题与图标在右、
/// 统计文字右对齐，和小说侧形成对称。
class _MineHeader extends StatelessWidget {
  const _MineHeader({
    required this.title,
    required this.icon,
    required this.stats,
    this.mirrored = false,
  });

  final String title;
  final IconData icon;
  final String stats;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleText = Text(
      title,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    );
    final iconBox = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 19, color: scheme.primary),
    );
    // 设置按钮由页面统一画在 Stack 顶层（切换时在屏幕内左右滑动），这里只留
    // 同宽的占位，保证两侧页头高度与文字位置不因移除按钮而变化。
    const settingsPlaceholder = SizedBox(width: 40, height: 40);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: mirrored
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            children: mirrored
                ? [
                    settingsPlaceholder,
                    const Spacer(),
                    titleText,
                    const SizedBox(width: 10),
                    iconBox,
                  ]
                : [
                    iconBox,
                    const SizedBox(width: 10),
                    titleText,
                    const Spacer(),
                    settingsPlaceholder,
                  ],
          ),
          const SizedBox(height: 8),
          Text(
            stats,
            textAlign: mirrored ? TextAlign.right : TextAlign.left,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块标题（我的书架 / 最近阅读 / 最近观看 / 我的收藏）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.hint, this.mirrored = false});

  final String title;
  final String? hint;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final hintText = hint == null
        ? null
        : Text(
            hint!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: mirrored
            ? [
                if (hintText != null) ...[hintText, const SizedBox(width: 8)],
                const Spacer(),
                titleText,
              ]
            : [
                Expanded(child: titleText),
                if (hintText != null) ...[const SizedBox(width: 8), hintText],
              ],
      ),
    );
  }
}
