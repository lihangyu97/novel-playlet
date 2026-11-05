import 'package:flutter/material.dart';

import '../../app/widgets/detail/detail_common.dart';
import '../../data/models/book_detail.dart';
import '../../data/models/novel_item.dart';

/// 小说详情顶部背景：只用封面，Hero 从列表卡片飞进来后直接铺成背景。
///
/// 封面固定以列表 preview 为准（详情接口回来不换图，避免二次加载闪一下）；
/// 列表没有封面时才回退到详情图。
class DetailHeroBackdrop extends StatelessWidget {
  const DetailHeroBackdrop({
    super.key,
    this.detail,
    this.preview,
    this.heroTag,
  });

  final BookDetail? detail;
  final NovelItem? preview;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final cover = _firstNonEmpty([preview?.cover, detail?.cover]);
    return DetailCoverBackdrop(cover: cover, heroTag: heroTag);
  }
}

/// 小说详情文字区：书名/作者/分类·状态·字数/评分/更新到。
///
/// 接口就绪后才构建（外层包 [DetailFadeIn]），所以这里不再需要 preview 兜底
/// 标题；preview 只在详情缺字段时补分类/字数。
class DetailHeroInfo extends StatelessWidget {
  const DetailHeroInfo({super.key, this.detail, this.preview});

  final BookDetail? detail;
  final NovelItem? preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final title = _firstNonEmpty([detail?.title, preview?.title]);
    final author = _firstNonEmpty([detail?.author, preview?.author]);
    final rawScore = _firstNonEmpty([detail?.score, preview?.score]);
    final score = rawScore == '0' || rawScore == '0.0' ? '' : rawScore;
    final readers = _readersLabel(detail?.readCount ?? '');
    final lastChapter = _firstNonEmpty([detail?.lastChapterTitle]);

    // 作者同一行带上状态/字数；分类去掉了（简介下面已经有标签，重复）。
    final subtitle = [
      if (author.isNotEmpty) author,
      if (detail != null && detail!.statusLabel.isNotEmpty)
        detail!.statusLabel,
      if (detail != null && detail!.wordLabel.isNotEmpty) detail!.wordLabel,
    ].join(' · ');

    // 评分 / 在读 / 更新至 合并成同一行。
    final infoStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final segments = <Widget>[];
    void addSeparator() {
      if (segments.isNotEmpty) segments.add(Text(' · ', style: infoStyle));
    }

    if (score.isNotEmpty) {
      segments.add(Icon(Icons.star_rounded, size: 16, color: scheme.primary));
      segments.add(const SizedBox(width: 3));
      segments.add(
        Text(
          score,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    if (readers.isNotEmpty) {
      addSeparator();
      segments.add(
        Flexible(
          child: Text(
            readers,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: infoStyle,
          ),
        ),
      );
    }
    if (lastChapter.isNotEmpty) {
      addSeparator();
      segments.add(
        Flexible(
          child: Text(
            '更新至 $lastChapter',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: infoStyle,
          ),
        ),
      );
    }

    return DetailTitleSection(
      title: title,
      subtitle: subtitle,
      extra: segments.isEmpty ? null : Row(children: segments),
    );
  }

}

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
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
