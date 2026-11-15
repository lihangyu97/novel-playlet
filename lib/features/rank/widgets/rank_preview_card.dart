import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../app/widgets/surface_card.dart';
import '../../../data/models/rank.dart';
import '../../recommend/recommend_category.dart';
import '../rank_entry_route.dart';
import '../rank_providers.dart';
import 'rank_entry_row.dart';

/// 首页瀑布流上方的榜单预览卡片。
///
/// 小说 tab 展示「推荐榜」、短剧 tab 展示「短剧榜」、漫剧 tab 展示「漫剧榜」；
/// 右上角「更多」带当前榜的 `algo` 进排行榜页，落地自动定位到同一档。
/// 榜单接口失败/空榜时整张卡片收起，推荐流本体不受影响。
class RankPreviewCard extends ConsumerWidget {
  const RankPreviewCard({super.key, required this.category});

  final RecommendCategory category;

  static const int previewCount = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rankPreviewProvider(category));
    final data = async.value;
    if (data == null || data.board.isEmpty) {
      // 首次进入 tab 时榜单还在路上：先铺一张同高的骨架卡，避免「先没有、
      // 切回来才出现」的错觉；失败/空榜（provider 返回 null）则直接收起。
      if (async.isLoading) return _RankPreviewSkeleton(category: category);
      return const SizedBox.shrink();
    }
    return RankPreviewCardView(data: data, category: category);
  }
}

String _previewTitle(RecommendCategory category) => switch (category) {
  RecommendCategory.novel => '推荐榜',
  RecommendCategory.drama => '短剧榜',
  RecommendCategory.anime => '漫剧榜',
};

class _RankPreviewSkeleton extends StatelessWidget {
  const _RankPreviewSkeleton({required this.category});

  final RecommendCategory category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: AppSurfaceCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            key: const Key('rank_preview_skeleton'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    _previewTitle(category),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < RankPreviewCard.previewCount; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SkeletonBox(
                        width: 46,
                        height:
                            46 *
                            (category == RecommendCategory.novel
                                ? kNovelCoverAspect
                                : kVideoCoverAspect),
                        radius: 6,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBar(width: 150, height: 12),
                            const SizedBox(height: 7),
                            SkeletonBar(width: 210, height: 9),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SkeletonBar(width: 34, height: 10),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 榜单预览卡片的纯视图（不读 provider），便于单独做 widget/golden 测试。
class RankPreviewCardView extends StatelessWidget {
  const RankPreviewCardView({
    super.key,
    required this.data,
    required this.category,
  });

  final RankPreviewData data;
  final RecommendCategory category;

  void _openRank(BuildContext context, RankTab tab) {
    context.pushAppRoute(RankRoute(initialAlgo: tab.algo));
  }

  void _openEntry(BuildContext context, RankEntry entry) {
    openRankEntry(context, entry, source: 'rank-preview-${category.name}');
  }

  @override
  Widget build(BuildContext context) {
    final entries = data.board.entries
        .take(RankPreviewCard.previewCount)
        .toList(growable: false);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: AppSurfaceCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    data.tab.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _openRank(context, data.tab),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.onSurfaceVariant,
                      textStyle: theme.textTheme.bodySmall,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('更多'),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (var index = 0; index < entries.length; index++)
                RankEntryRow(
                  entry: entries[index],
                  dense: true,
                  source: 'rank-preview-${category.name}',
                  onTap: () => _openEntry(context, entries[index]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
