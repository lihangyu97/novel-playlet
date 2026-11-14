import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/comment_image_strip.dart';
import '../../app/widgets/detail/detail_common.dart';
import '../../data/models/book_comment.dart';

/// 详情页书评 / 剧评卡片：只露第一条 + 「查看全部 N 条」，点整张卡打开弹层。
///
/// 卡片常驻，不等接口：请求中在卡片里显示 loading，没有评论（或请求失败）
/// 时显示「暂无评论」。书评是次要信息，不单独制造错误态，也不让区块忽隐忽现
/// 把下面的目录 / 选集顶上顶下。
class DetailReviewsSection extends StatelessWidget {
  const DetailReviewsSection({
    super.key,
    required this.reviews,
    required this.onOpenAll,
    this.title = '书评',
    this.showStars = true,
  });

  /// 书评第一页的请求状态；null 数据 = 没有评论 / 请求失败。
  final AsyncValue<BookCommentPage?> reviews;

  /// 区块标题。小说详情是「书评」，短剧详情传「剧评」。
  final String title;

  /// 是否画 5 星评分。短剧评论没有评分字段，传 false 避免一排空星。
  final bool showStars;

  /// 有评论时点整卡打开全部评论弹层。
  final ValueChanged<BookCommentPage> onOpenAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final page = reviews.value;
    // 请求失败会返回 null，按「没有评论」处理。
    final loaded = page != null && page.comments.isNotEmpty ? page : null;
    final loading = reviews.isLoading && page == null;

    return Card(
      margin: const EdgeInsets.fromLTRB(detailGutter, 6, detailGutter, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: loaded == null ? null : () => onOpenAll(loaded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            detailGutter,
            detailGutter,
            detailGutter,
            12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailSectionHeader(
                title: title,
                // 卡片自己已经有 gutter 内边距，标题行不再重复留白。
                padding: EdgeInsets.zero,
                trailing: loaded == null || loaded.context.isEmpty
                    ? null
                    : Text(
                        loaded.context,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(height: 10),
              if (loading)
                const _ReviewsLoading()
              else if (loaded == null)
                const _ReviewsEmpty()
              else
                _LoadedReviews(page: loaded, showStars: showStars),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书评区 loading：只占卡片内部，整张卡（标题 + 边框）已经在位。
class _ReviewsLoading extends StatelessWidget {
  const _ReviewsLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    );
  }
}

/// 没有书评 / 请求失败：卡片保留，正文位置给一句空态。
class _ReviewsEmpty extends StatelessWidget {
  const _ReviewsEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Center(
        child: Text(
          '暂无评论',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 有数据时的首条书评 + 「查看全部 N 条」。
class _LoadedReviews extends StatelessWidget {
  const _LoadedReviews({required this.page, required this.showStars});

  final BookCommentPage page;
  final bool showStars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // comment_cnt 缺失时（旧接口偶发）退回本页条数，至少不会显示「查看全部 0 条」。
    final total = page.totalCount > 0 ? page.totalCount : page.comments.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailReviewRow(comment: page.comments.first, showStars: showStars),
        const SizedBox(height: 8),
        // 右下角只做视觉提示：整张卡都可点，所以这里不再套第二层按钮，
        // 避免出现两个互相竞争的点击热区。
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '查看全部 $total 条',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: scheme.primary,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一条书评的通用行：头像（昵称首字，不拉网络图）+ 昵称 + 5 星 + 正文 +
/// 点赞/时间。详情页卡片与书评弹层共用，保证两处排版完全一致。
class DetailReviewRow extends StatelessWidget {
  const DetailReviewRow({
    super.key,
    required this.comment,
    this.maxLines,
    this.padding = EdgeInsets.zero,
    this.showStars = true,
  });

  final BookComment comment;

  /// 是否画 5 星评分；短剧评论没有评分，传 false。
  final bool showStars;

  /// 正文行数上限；null = 不限制（弹层里完整展示）。
  final int? maxLines;

  /// 行内边距：详情页卡片由外层控制，弹层里用来和分隔线对齐。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = comment.userName.trim();
    // 头像不拉网络图（详情页不需要为几条书评再开图片请求），用昵称首字；
    // 昵称缺失时给一个占位字，避免出现空白圆。
    final initial = name.isEmpty ? '读' : String.fromCharCode(name.runes.first);
    final text = comment.text.trim();
    final time = comment.timeLabel();
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              initial,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name.isEmpty ? '匿名读者' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showStars) ...[
                      const SizedBox(width: 8),
                      DetailReviewStars(stars: comment.stars),
                    ],
                  ],
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    text,
                    maxLines: maxLines,
                    overflow: maxLines == null
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ],
                if (comment.imageUrls.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  CommentImageStrip(imageRefs: comment.imageRefsOrFallback),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.thumb_up_alt_outlined,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 3),
                    Text('${comment.diggCount}', style: metaStyle),
                    if (time.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Text(time, style: metaStyle),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 5 星评分：上游 score 为 0–10 分，折半后按 0.5 星粒度画整星/半星/空星。
class DetailReviewStars extends StatelessWidget {
  const DetailReviewStars({super.key, required this.stars});

  final double stars;

  static const double _size = 14;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            stars >= i + 1
                ? Icons.star_rounded
                : stars >= i + 0.5
                ? Icons.star_half_rounded
                : Icons.star_border_rounded,
            size: _size,
            // 空星压暗一档，否则 0 分书评看起来也像满屏高亮。
            color: stars >= i + 0.5
                ? scheme.primary
                : scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
      ],
    );
  }
}
