import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/widgets/cover_hero.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../app/widgets/states.dart';
import '../../../core/storage/reading_store.dart';
import '../../../data/models/novel_item.dart';
import '../mine_providers.dart';
import 'media_manage_sheet.dart';
import 'mine_grid_metrics.dart';
import 'mine_header.dart';
import 'mine_recent_reading.dart';
import 'mine_shelf_grid.dart';
import 'mine_tab_body.dart';

/// 「小说」tab：书架 + 最近阅读。
///
/// 页头与 tabs 由 [MinePage] 固定贴顶；这里只读本地数据并注入 [MineTabBody]。
///
/// 书架订阅 [mineShelfProvider]，最近阅读由 [_MineRecentReadingSection] 单独
/// 订阅 [mineRecentProvider]：阅读页每 400ms 落一次进度时只重建最近阅读那一块，
/// 书架网格（以及 tab 本身）不重建（CODE_REVIEW P1-5）。
class MineNovelTab extends ConsumerWidget {
  const MineNovelTab({super.key, required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineShelfProvider);
    final shelf = async.value;
    final metrics = MineGridMetrics.of(context);
    return MineTabBody(
      bottomInset: bottomInset,
      placeholder: async.hasError
          ? ErrorView(
              message: '读取本地书架失败，请重试',
              onRetry: () => ref.invalidate(mineShelfProvider),
            )
          : const LoadingView(label: '正在读取书架…'),
      recent: const _MineRecentReadingSection(),
      grid: shelf == null
          ? null
          : Column(
              children: [
                MineSectionHeader(
                  title: '我的书架',
                  hint: shelf.isEmpty ? null : '长按管理',
                ),
                MineShelfGrid(
                  shelf: shelf,
                  crossAxisCount: metrics.columns,
                  itemWidth: metrics.itemWidth,
                  spacing: MineGridMetrics.spacing,
                  coverAspect: kNovelCoverAspect,
                  heroTagOf: (item) =>
                      CoverHeroTag.novel('mine-shelf', item.id),
                  onOpen: (item) => _openDetail(context, item),
                  onLongPress: (item) => _showShelfMenu(context, ref, item),
                ),
              ],
            ),
    );
  }

  void _openDetail(BuildContext context, NovelItem item) {
    context.pushAppRoute(
      DetailRoute(
        bookId: item.id,
        preview: item,
        heroTag: CoverHeroTag.novel('mine-shelf', item.id),
      ),
    );
  }

  Future<void> _showShelfMenu(
    BuildContext context,
    WidgetRef ref,
    NovelItem item,
  ) {
    return showMediaManageSheet(
      context: context,
      title: item.title,
      removeLabel: '移出书架',
      openDetail: () => _openDetail(context, item),
      remove: () => ref.read(readingStoreProvider).removeFromShelf(item.id),
      removedMessage: '已把《${item.title}》移出书架',
    );
  }
}

/// 最近阅读：独立订阅进度通道，阅读时只有这一块重建。
class _MineRecentReadingSection extends ConsumerWidget {
  const _MineRecentReadingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(mineRecentProvider).value;
    if (recent == null || recent.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        const MineSectionHeader(title: '最近阅读'),
        MineRecentReading(
          items: recent,
          onOpen: (item) => _openReader(context, item),
        ),
      ],
    );
  }

  void _openReader(BuildContext context, ReadingProgress progress) {
    context.pushAppRoute(
      ReaderRoute(
        ReaderArgs(
          bookId: progress.bookId,
          bookTitle: progress.bookTitle,
          cover: progress.cover,
          chapterId: progress.chapterId,
          chapterIndex: progress.chapterIndex,
          blockIndex: progress.blockIndex,
        ),
      ),
    );
  }
}
