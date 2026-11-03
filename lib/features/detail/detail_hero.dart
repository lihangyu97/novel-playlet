import 'package:flutter/material.dart';

import '../../app/widgets/novel_cover.dart';
import '../../data/models/book_detail.dart';
import '../../data/models/novel_item.dart';
import 'detail_style.dart';

/// 详情页顶部 Hero：大封面 + 书名/作者/分类·状态·字数/评分/更新到。
///
/// [detail] 是接口数据；加载阶段只有 [preview]（列表卡片）。此时用它的
/// 封面与标题先把版式撑起来，避免整页白屏。
class DetailHero extends StatelessWidget {
  const DetailHero({super.key, this.detail, this.preview});

  final BookDetail? detail;
  final NovelItem? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final title = _firstNonEmpty([detail?.title, preview?.title]);
    final cover = _firstNonEmpty([detail?.cover, preview?.cover]);
    // 列表封面（thumb_url）与详情封面（detail_page_thumb_url）是两张不同 URL
    // 的图：详情图更大更清晰，但换 URL 必然重新下载。垫着列表那张直接替换，
    // 不要灰块和淡入，否则从列表点进来会看到封面"刷新"一下。
    final coverFallback = preview != null && preview!.cover != cover
        ? preview!.cover
        : '';
    // 深链进入且还没有任何数据时，这里不画空壳，交给下方的 Loading/Error
    // 占满视口。
    if (title.isEmpty && cover.isEmpty) return const SizedBox.shrink();

    final author = _firstNonEmpty([detail?.author, preview?.author]);
    final meta = _metaLabel();
    final rawScore = _firstNonEmpty([detail?.score, preview?.score]);
    final score = rawScore == '0' || rawScore == '0.0' ? '' : rawScore;
    final readers = _readersLabel(detail?.readCount ?? '');
    final lastChapter = _firstNonEmpty([detail?.lastChapterTitle]);
    final showRating = score.isNotEmpty || readers.isNotEmpty;

    // 沉浸式：页面没有导航栏，Hero 自己让出状态栏高度 + 8pt 呼吸位，内容
    // 从安全区下方开始，渐变背景仍铺到屏幕顶。
    return Container(
      padding: EdgeInsets.fromLTRB(
        detailGutter + 4,
        MediaQuery.paddingOf(context).top + 8,
        detailGutter + 4,
        detailGutter + 4,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.primary.withValues(alpha: 0.12),
            scheme.primary.withValues(alpha: 0),
          ],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NovelCover(
            url: cover,
            width: 96,
            height: 132,
            fallbackUrl: coverFallback,
            fadeInDuration: Duration.zero,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (author.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (showRating) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (score.isNotEmpty) ...[
                        Icon(
                          Icons.star_rounded,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          score,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (score.isNotEmpty && readers.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          '·',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (readers.isNotEmpty)
                        Flexible(
                          child: Text(
                            readers,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (lastChapter.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '更新至 $lastChapter',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 详情优先；加载中退回卡片的分类/字数，让 Hero 的骨架和最终版更接近。
  String _metaLabel() {
    final parts = detail?.metaParts ?? const <String>[];
    if (parts.isNotEmpty) return parts.join(' · ');
    return [
      if (preview != null && preview!.category.isNotEmpty) preview!.category,
      if (preview != null) _wordLabel(preview!.wordCount),
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final text = value?.trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _wordLabel(int count) {
    if (count <= 0) return '';
    if (count < 10000) return '$count字';
    final wan = count / 10000;
    return '${wan.toStringAsFixed(wan >= 100 ? 0 : 1)}万字';
  }

  /// 上游 `read_count` 可能是纯数字或已经带单位（「12.4万」），两种都要能显示。
  String _readersLabel(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final value = int.tryParse(text);
    if (value == null) return text.endsWith('在读') ? text : '$text人在读';
    if (value < 10000) return '$value人在读';
    final wan = value / 10000;
    final label = wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(1);
    return '$label万人在读';
  }
}
