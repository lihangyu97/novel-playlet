import 'package:flutter/material.dart';

import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_cover.dart';

/// 搜索结果的条目形态：封面 + 标题 + 元信息 + 简介两行。
///
/// 推荐页三个分类的搜索结果共用同一个条目：小说搜索与短剧/漫剧搜索都走这里，
/// 封面宽度/字距/分隔线一致，高度随分类原生比例（小说 3:4、短剧/漫剧 7:10），
/// 差异只有 [meta] 文案（作者·分类 / 全 N 集）。
class FeedResultTile extends StatelessWidget {
  const FeedResultTile({
    super.key,
    required this.cover,
    required this.coverAspect,
    required this.title,
    required this.meta,
    required this.intro,
    required this.onTap,
    this.heroTag,
  });

  /// 封面宽度。高度 = 宽 × [coverAspect]：小说 64×85.3、短剧/漫剧 64×91.4。
  static const double coverWidth = 64;

  /// 行内水平留白：与搜索框/推荐流左右边距一致（8）。
  static const double gutter = 8;

  /// 文字左边缘相对行首的偏移：分隔线按它缩进，跟标题左对齐。
  static const double dividerIndent = gutter + coverWidth + 12;

  final String cover;

  /// 封面原生比例（高 / 宽）：小说 [kNovelCoverAspect]、短剧/漫剧
  /// [kVideoCoverAspect]，由列表所属分类决定。
  final double coverAspect;
  final String title;
  final String meta;
  final String intro;
  final VoidCallback onTap;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverHero(
              tag: heroTag,
              child: NovelCover(
                url: cover,
                width: coverWidth,
                height: coverWidth * coverAspect,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (intro.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.4,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.9,
                        ),
                      ),
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

/// 搜索结果的横向列表（sliver 形态）：小说/短剧共用一套条目与分隔线。
class FeedResultsSliver<T> extends StatelessWidget {
  const FeedResultsSliver({
    super.key,
    required this.items,
    required this.coverAspect,
    required this.coverOf,
    required this.titleOf,
    required this.metaOf,
    required this.introOf,
    required this.onTap,
    this.heroTagOf,
  });

  final List<T> items;

  /// 这个分类的封面原生比例（高 / 宽），透传给 [FeedResultTile]。
  final double coverAspect;
  final String Function(T item) coverOf;
  final String Function(T item) titleOf;

  /// 第二行文案；返回空串则整行不占位。
  final String Function(T item) metaOf;
  final String Function(T item) introOf;
  final ValueChanged<T> onTap;

  /// 封面 Hero tag；null = 这一页不参与飞入动画。
  final String Function(T item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    return SliverList.separated(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return FeedResultTile(
          cover: coverOf(item),
          coverAspect: coverAspect,
          title: titleOf(item),
          meta: metaOf(item),
          intro: introOf(item),
          onTap: () => onTap(item),
          heroTag: heroTagOf?.call(item),
        );
      },
      separatorBuilder: (context, index) => const Divider(
        indent: FeedResultTile.dividerIndent,
        endIndent: FeedResultTile.gutter,
      ),
    );
  }
}
