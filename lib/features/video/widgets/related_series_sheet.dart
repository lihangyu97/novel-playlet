import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/app_bottom_sheet.dart';
import '../../../app/widgets/novel_cover.dart';
import '../../../app/widgets/states.dart';
import '../../../core/season_title.dart';
import '../../../data/models/video_series.dart';

/// 把「剧名 + 第 x 集 / 第 x 季」清洗成搜索词。
///
/// 上游有些剧名本身带季/集号（`某剧 第12集`、`某剧（第二季）`、`某剧 [第9话]`、
/// `某剧 第2季 第3集`），直接拿去搜会把序号也算进关键词。季和集都去掉：
/// 每季是独立 `series_id`，去掉季号才能搜到同系列其它季与相近短剧。
/// 清洗后为空（标题只有「第 1 集」）时退回原剧名，避免发空查询。
String relatedSearchQuery(String seriesTitle) {
  final withoutSeason = stripSeasonMarker(seriesTitle);
  final withoutNumbers = withoutSeason.replaceAll(
    RegExp(
      r'[\[\(（【]?\s*第\s*'
      r'(?:[0-9]+|[零一二两三四五六七八九十百千]{1,4})'
      r'\s*[集话期]\s*[\]\)）】]?',
    ),
    ' ',
  );
  final cleaned = _cleanQuery(withoutNumbers);
  if (cleaned.isNotEmpty) return cleaned;
  // 标题本身只有序号时退回原剧名，避免拿空串去搜。
  final fallback = _cleanQuery(seriesTitle);
  return fallback.isEmpty ? seriesTitle.trim() : fallback;
}

String _cleanQuery(String raw) => raw
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[·\-—_|：:]+'), '')
    .replaceAll(RegExp(r'[·\-—_|：:]+$'), '')
    .trim();

/// 播放页「相关」底部弹层：用当前剧名搜短剧/漫剧，点一条返回 [VideoSeries]。
///
/// 只搜剧、不搜小说；搜到当前正在播的那部会被过滤掉。弹层本身不做跳转，
/// 由播放页拿到结果后决定怎么进（当前是 replace 到该剧第 1 集）。
Future<VideoSeries?> showRelatedSeriesSheet({
  required BuildContext context,
  required String seriesTitle,
  required String excludeSeriesId,
}) {
  final query = relatedSearchQuery(seriesTitle);
  if (query.isEmpty) return Future<VideoSeries?>.value();
  return showAppBottomSheet<VideoSeries>(
    context: context,
    builder: (_) =>
        RelatedSeriesSheet(query: query, excludeSeriesId: excludeSeriesId),
  );
}

class RelatedSeriesSheet extends ConsumerStatefulWidget {
  const RelatedSeriesSheet({
    super.key,
    required this.query,
    required this.excludeSeriesId,
  });

  final String query;

  /// 当前正在播放的剧：搜索结果里过滤掉，避免「相关」搜到自己。
  final String excludeSeriesId;

  @override
  ConsumerState<RelatedSeriesSheet> createState() => _RelatedSeriesSheetState();
}

class _RelatedSeriesSheetState extends ConsumerState<RelatedSeriesSheet> {
  late Future<List<VideoSeries>> _future;

  @override
  void initState() {
    super.initState();
    _future = _search();
  }

  Future<List<VideoSeries>> _search() async {
    final page = await ref
        .read(apiClientProvider)
        .searchVideos(widget.query, tabType: 11);
    return page.items
        .where((item) => item.isValid && item.id != widget.excludeSeriesId)
        .toList(growable: false);
  }

  void _retry() {
    setState(() => _future = _search());
  }

  @override
  Widget build(BuildContext context) {
    return AppBottomSheet(
      title: '相关',
      subtitle: '「${widget.query}」的相关短剧',
      heightFactor: 0.72,
      child: FutureBuilder<List<VideoSeries>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorView(message: '加载相关短剧失败，请重试', onRetry: _retry);
          }
          final items = snapshot.data;
          if (items == null) {
            return const LoadingView(label: '正在搜索相关短剧…');
          }
          if (items.isEmpty) {
            return const EmptyView(
              message: '没有找到相关短剧',
              icon: Icons.search_off_rounded,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            itemCount: items.length,
            separatorBuilder: (context, index) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final item = items[index];
              return _RelatedSeriesTile(
                item: item,
                onTap: () => Navigator.of(context).pop(item),
              );
            },
          );
        },
      ),
    );
  }
}

/// 相关短剧的一行：封面 + 剧名 + 「全 N 集 · 评分」。
class _RelatedSeriesTile extends StatelessWidget {
  const _RelatedSeriesTile({required this.item, required this.onTap});

  final VideoSeries item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      if (item.episodeCount > 0) '全 ${item.episodeCount} 集',
      if (item.score.isNotEmpty) '${item.score} 分',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            // 短剧封面按上游原生比例（≈10:7）裁一档，列表行里不抢标题宽度。
            NovelCover(
              url: item.cover,
              width: 76,
              height: 54,
              radius: 6,
              placeholderColor: coverPlaceholderColorOf(item.colorDominate),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: context.appWeight(FontWeight.w600),
                    ),
                  ),
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
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
