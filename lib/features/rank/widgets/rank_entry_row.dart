import 'package:flutter/material.dart';

import '../../../app/widgets/app_pill.dart';
import '../../../app/widgets/cover_hero.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../data/models/rank.dart';
import '../rank_entry_route.dart';

/// 榜单条目行：排行榜页（完整）与首页榜单预览卡（[dense]）共用。
///
/// 完整行：名次 + 封面 + 标题/评分 + 元信息 + 两行简介 + 题材标签。
/// 紧凑行：封面 + 标题/评分 + 元信息（无名次/简介/标签），给首页卡片用。
/// 两种密度只差排版，封面 Hero、点击路由、字段读取都走同一份。
class RankEntryRow extends StatelessWidget {
  const RankEntryRow({
    super.key,
    required this.entry,
    required this.source,
    required this.onTap,
    this.dense = false,
  });

  final RankEntry entry;

  /// 来源标识（进 Hero tag 与路由），如 `rank-101` / `rank-preview-novel`。
  final String source;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final coverAspect = entry.isVideo ? kVideoCoverAspect : kNovelCoverAspect;
    final heroTag = rankEntryHeroTag(entry, source);
    final coverWidth = dense ? 46.0 : 56.0;
    final coverRadius = dense ? 6.0 : 8.0;

    final cover = CoverHero(
      tag: heroTag,
      child: NovelCover(
        url: entry.cover,
        width: coverWidth,
        height: coverWidth * coverAspect,
        radius: coverRadius,
        placeholderColor: coverPlaceholderColorOf(entry.colorDominate),
      ),
    );
    final score = entry.scoreLabel.isEmpty
        ? null
        : Text(
            entry.scoreLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontSize: dense ? 12 : 12.5,
              height: dense ? 1.2 : 1.2,
              fontWeight: dense ? FontWeight.w600 : FontWeight.w700,
            ),
          );

    if (dense) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              cover,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface,
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.metaLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (score != null) ...[const SizedBox(width: 8), score],
            ],
          ),
        ),
      );
    }

    final top = entry.position <= 3;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${entry.position}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: top ? scheme.error : scheme.onSurfaceVariant,
                    fontSize: top ? 16 : 13,
                    height: 1.2,
                    fontWeight: top ? FontWeight.w700 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            cover,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                            fontSize: 14.5,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (score != null) ...[const SizedBox(width: 8), score],
                    ],
                  ),
                  if (entry.metaLabel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.metaLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                  if (entry.abstract.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      entry.abstract.replaceAll(RegExp(r'\s+'), ' ').trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                        fontSize: 11.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (entry.tags.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final tag in entry.tags.take(3))
                          AppPill(label: tag),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
