import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../core/cache/app_cache.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/novel_item.dart';
import 'mine_providers.dart';
import 'widgets/mine_recent_reading.dart';
import 'widgets/mine_shelf_grid.dart';

/// 我的：应用名 + 本地书架 + 最近阅读。
///
/// 全部数据都在本地（书架 + 阅读进度），没有网络请求。书架/进度一变，
/// [mineDataProvider] 会因为 [readingRevisionProvider] 失效而自动重取，
/// 因此从详情页加书架、从阅读页保存进度后回到这里，数据已经是新的。
/// 页面只做布局与交互，异步状态由 provider 承载，不使用 setState。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  static const _gutter = 16.0;
  static const _gridSpacing = 12.0;

  /// 卡片目标宽度：手机 3 列、iPad 自动增列，避免宽屏上封面被拉得过大。
  static const _maxCardWidth = 128.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDataProvider);
    final data = async.value;
    // 缓存占用单独一个 provider：它跟书架/进度无关，清理后单独 invalidate。
    final cacheUsage = ref.watch(cacheUsageProvider).value;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 需求：除小说推荐页外都不做下拉刷新、也不做橡皮筋回弹；
            // 书架数据在本地，进页面读一次即可，返回时由 provider 自动更新。
            return CustomScrollView(
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _MineHeader(
                    shelfCount: data?.shelf.length,
                    recentCount: data?.recent.length,
                    statusText: async.hasError ? '本地书架暂时读不出来' : null,
                  ),
                ),
                if (data != null)
                  ..._contentSlivers(
                    context,
                    ref,
                    constraints.maxWidth,
                    data,
                    cacheUsage,
                  )
                else if (async.hasError)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: ErrorView(
                      message: '读取本地书架失败，请重试',
                      onRetry: () => ref.invalidate(mineDataProvider),
                    ),
                  )
                else
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: LoadingView(label: '正在读取书架…'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _contentSlivers(
    BuildContext context,
    WidgetRef ref,
    double maxWidth,
    MineData data,
    CacheUsage? cacheUsage,
  ) {
    final available = math.max(0.0, maxWidth - _gutter * 2);
    final columns = math.max(
      2,
      math.min(6, (available / _maxCardWidth).ceil()),
    );
    final itemWidth = math.max(
      0.0,
      (available - _gridSpacing * (columns - 1)) / columns,
    );
    // 与 NovelGridCard 的内部排版对齐（封面 kCoverAspect 比例 + 标题两行 +
    // 作者一行），再按系统字体缩放留出高度，避免网格单元格比卡片矮造成溢出。
    final textScaler = MediaQuery.textScalerOf(context);
    final itemHeight =
        itemWidth * kCoverAspect +
        8 +
        textScaler.scale(14) * 1.25 * 2 +
        3 +
        textScaler.scale(12) * 1.35 +
        6;

    return [
      // 最近阅读在上、书架在下：最近读的几本是最常用的入口。
      if (data.recent.isNotEmpty) ...[
        const SliverToBoxAdapter(child: _SectionHeader(title: '最近阅读')),
        MineRecentReading(
          items: data.recent,
          onOpen: (progress) => _openReader(context, progress),
        ),
      ],
      SliverToBoxAdapter(
        child: _SectionHeader(
          title: '我的书架',
          hint: data.shelf.isEmpty ? null : '长按管理',
        ),
      ),
      MineShelfGrid(
        shelf: data.shelf,
        crossAxisCount: columns,
        itemWidth: itemWidth,
        itemHeight: itemHeight,
        spacing: _gridSpacing,
        onOpen: (item) => _openDetail(context, item),
        onLongPress: (item) => _showShelfMenu(context, ref, item),
      ),
      // 缓存放在最下面：演示/调试期间最容易堆的是它，用户来这里清一次。
      const SliverToBoxAdapter(child: _SectionHeader(title: '存储')),
      SliverToBoxAdapter(
        child: _CacheTile(
          usage: cacheUsage,
          onClear: () => _clearCache(context, ref),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
    ];
  }

  /// 清空可重建缓存（视频/封面/章节），书架与进度不动。
  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final freed = await AppCache.instance.clear();
    ref.invalidate(cacheUsageProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(freed > 0 ? '已清理 ${formatBytes(freed)} 缓存' : '没有可清理的缓存'),
      ),
    );
  }

  void _openDetail(BuildContext context, NovelItem item) {
    Navigator.of(context).pushNamed(
      AppRoutes.detail,
      arguments: DetailArgs(bookId: item.id, preview: item),
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

/// 页头：应用名 + 一行统计。书架与最近阅读的计数在上方一眼可见。
class _MineHeader extends StatelessWidget {
  const _MineHeader({
    required this.shelfCount,
    required this.recentCount,
    required this.statusText,
  });

  final int? shelfCount;
  final int? recentCount;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shelf = shelfCount;
    final recent = recentCount;
    final stats = shelf != null && recent != null
        ? '最近阅读 $recent 本 · 书架 $shelf 本'
        : (statusText ?? '正在读取书架…');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.auto_stories_rounded,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '小说铺',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stats,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 缓存占用行：图标 + 明细（视频/封面/章节）+「清理」。
///
/// 数字是「某一刻的快照」：视频缓存只有播放时才会变，所以进页面/清理后各算
/// 一次，不做实时轮询。
class _CacheTile extends StatelessWidget {
  const _CacheTile({required this.usage, required this.onClear});

  final CacheUsage? usage;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = usage;
    final detail = current == null
        ? '正在统计…'
        : current.isEmpty
        ? '暂无缓存'
        : _detailOf(current);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Icon(
            Icons.cleaning_services_outlined,
            size: 19,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '缓存占用',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: current == null || current.isEmpty ? null : onClear,
            child: const Text('清理'),
          ),
        ],
      ),
    );
  }

  /// 明细：总量放最前（万一被省略号截断，用户仍能看到总数），再列 ≥1 MB 的
  /// 大头；章节/日志这类零碎项不值得占一行。
  static String _detailOf(CacheUsage usage) {
    const mb = 1024 * 1024;
    final parts = [
      if (usage.video >= mb) '视频 ${formatBytes(usage.video)}',
      if (usage.image >= mb) '封面 ${formatBytes(usage.image)}',
      if (usage.chapter >= mb) '章节 ${formatBytes(usage.chapter)}',
    ];
    final total = '共 ${formatBytes(usage.total)}';
    return parts.isEmpty ? total : '$total · ${parts.join(' · ')}';
  }
}

/// 区块标题（我的书架 / 最近阅读）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Text(
              hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
