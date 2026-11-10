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
class MineNovelTab extends ConsumerWidget {
  const MineNovelTab({super.key, required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mineDataProvider);
    final data = async.value;
    final metrics = MineGridMetrics.of(context, coverAspect: kNovelCoverAspect);
    return MineTabBody<MineData>(
      data: data,
      bottomInset: bottomInset,
      placeholder: async.hasError
          ? ErrorView(
              message: '读取本地书架失败，请重试',
              onRetry: () => ref.invalidate(mineDataProvider),
            )
          : const LoadingView(label: '正在读取书架…'),
      recentOf: (data) => data.recent.isEmpty
          ? null
          : Column(
              children: [
                const MineSectionHeader(title: '最近阅读'),
                MineRecentReading(
                  items: data.recent,
                  onOpen: (item) => _openReader(context, item),
                ),
              ],
            ),
      gridOf: (data) => Column(
        children: [
          MineSectionHeader(
            title: '我的书架',
            hint: data.shelf.isEmpty ? null : '长按管理',
          ),
          MineShelfGrid(
            shelf: data.shelf,
            crossAxisCount: metrics.columns,
            itemWidth: metrics.itemWidth,
            itemHeight: metrics.itemHeight,
            spacing: MineGridMetrics.spacing,
            coverAspect: kNovelCoverAspect,
            heroTagOf: (item) => CoverHeroTag.novel('mine-shelf', item.id),
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
