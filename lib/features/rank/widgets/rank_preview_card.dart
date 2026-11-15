import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/compact_card_row.dart';
import '../../../app/widgets/cover_hero.dart';
import '../../../app/widgets/novel_card.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../data/models/rank.dart';
import '../../recommend/recommend_category.dart';
import '../../video/widgets/video_card.dart';
import '../rank_providers.dart';

/// 首页瀑布流上方的榜单区块。
///
/// 版式与搜索结果页的分类行一致：榜名（推荐榜 / 短剧榜 / 漫剧榜）在卡片
/// **外面**，右侧「更多」带当前榜的 `algo` 进排行榜页、落地自动定位；下面
/// 是一行横向可滑的紧凑卡（与搜索结果同一套宽度/字号，见 [CompactCardRow]），
/// 只取前三。榜单接口失败/空榜时整块收起，推荐流本体不受影响。
class RankPreviewCard extends ConsumerWidget {
  const RankPreviewCard({super.key, required this.category});

  final RecommendCategory category;

  static const int previewCount = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rankPreviewProvider(category));
    final data = async.value;
    if (data == null || data.board.isEmpty) {
      // 首次进入 tab 时榜单还在路上：先铺同口径的骨架，避免「先没有、
      // 切回来才出现」的错觉；失败/空榜（provider 返回 null）则直接收起。
      if (async.isLoading) return _RankPreviewSkeleton(category: category);
      return const SizedBox.shrink();
    }
    return RankPreviewCardView(data: data, category: category);
  }
}

/// 骨架用的榜名：目录还没回来时按分类给一个确定文案，和真数据同位置。
String _previewTitle(RecommendCategory category) => switch (category) {
  RecommendCategory.novel => '推荐榜',
  RecommendCategory.drama => '短剧榜',
  RecommendCategory.anime => '漫剧榜',
};

/// 榜单区块的标题行：榜名在卡片外面，右侧「更多」。
///
/// 版式对齐搜索结果页的分类标题（titleMedium + w600、左右 8 留白），只把
/// 「更多」放在同一行右侧；骨架态不传 [onMore]（按钮不可点就不该出现）。
class _RankSectionHeader extends StatelessWidget {
  const _RankSectionHeader({required this.title, this.onMore});

  final String title;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      // 左边与内容留白对齐；右边少留 4，让「更多 >」的箭头贴近内容边。
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 6),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: context.appWeight(FontWeight.w600),
            ),
          ),
          const Spacer(),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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
    );
  }
}

/// 榜单预览骨架：标题先出（榜名按分类映射），下面铺与真卡同口径的 3 张
/// 骨架卡，接口回来换真卡时高度不跳。
class _RankPreviewSkeleton extends StatelessWidget {
  const _RankPreviewSkeleton({required this.category});

  final RecommendCategory category;

  @override
  Widget build(BuildContext context) {
    final coverAspect = category == RecommendCategory.novel
        ? kNovelCoverAspect
        : kVideoCoverAspect;
    return Column(
      key: const Key('rank_preview_skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RankSectionHeader(title: _previewTitle(category)),
        LayoutBuilder(
          builder: (context, constraints) => CompactSkeletonRow(
            width: CompactCardRow.cardWidthFor(constraints.maxWidth),
            coverAspect: coverAspect,
            count: RankPreviewCard.previewCount,
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// 榜单预览区块的纯视图（不读 provider），便于单独做 widget/golden 测试。
class RankPreviewCardView extends StatelessWidget {
  const RankPreviewCardView({
    super.key,
    required this.data,
    required this.category,
  });

  final RankPreviewData data;
  final RecommendCategory category;

  /// Hero tag 的来源维度：同一本书可能同时出现在榜单预览与推荐流里，tag 必须
  /// 带页面与分类，否则两个列表里的 Hero 会撞 tag。
  String get _heroSource => 'rank-preview-${category.name}';

  void _openRank(BuildContext context, RankTab tab) {
    context.pushAppRoute(RankRoute(initialAlgo: tab.algo));
  }

  void _openEntry(BuildContext context, RankEntry entry) {
    if (entry.isEmpty) return;
    final source = _heroSource;
    final route = entry.isVideo
        ? VideoDetailRoute(
            seriesId: entry.id,
            preview: entry.toVideoSeries(),
            heroTag: CoverHeroTag.video(source, entry.id),
          )
        : DetailRoute(
            bookId: entry.id,
            preview: entry.toNovelItem(),
            heroTag: CoverHeroTag.novel(source, entry.id),
          );
    context.pushAppRoute(route);
  }

  /// 榜单条目 → 与搜索结果同款的紧凑卡：封面按内容域原生比例、评分走封面
  /// 角标，元信息只有作者（短剧/漫剧为集数），热度有就单独一行。
  Widget _card(BuildContext context, RankEntry entry, double width) {
    final heroTag = entry.isVideo
        ? CoverHeroTag.video(_heroSource, entry.id)
        : CoverHeroTag.novel(_heroSource, entry.id);
    void onTap() => _openEntry(context, entry);
    if (entry.isVideo) {
      return VideoCard(
        key: ValueKey('rank-preview-${entry.id}'),
        item: entry.toVideoSeries(),
        width: width,
        onTap: onTap,
        heroTag: heroTag,
        showRecommendMeta: true,
        // 榜单没有推荐理由，关掉理由只留集数与热度（与搜索卡一致）。
        showReason: false,
        coverAspect: kVideoCoverAspect,
        surface: true,
      );
    }
    return NovelGridCard(
      key: ValueKey('rank-preview-${entry.id}'),
      item: entry.toNovelItem(),
      width: width,
      onTap: onTap,
      heroTag: heroTag,
      showRecommendMeta: true,
      coverAspect: kNovelCoverAspect,
      surface: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = data.board.entries
        .take(RankPreviewCard.previewCount)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RankSectionHeader(
          title: data.tab.name,
          onMore: () => _openRank(context, data.tab),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = CompactCardRow.cardWidthFor(constraints.maxWidth);
            return CompactCardRow(
              children: [
                for (final entry in entries) _card(context, entry, width),
              ],
            );
          },
        ),
        // 与下面的推荐瀑布流留一段；瀑布流自己不带顶部间距。
        const SizedBox(height: 12),
      ],
    );
  }
}
