import 'package:flutter/material.dart';

import '../../widgets/novel_cover.dart';

/// 详情页左右留白。卡片、目录行、底部操作栏共用，保证竖线对齐。
const double detailGutter = 16;

/// 详情页顶部：封面 + 标题/副标题/元信息 + 自定义附加行。
///
/// 小说详情与短剧详情共用同一套版式（沉浸式渐变、96×132 封面、同一套字号
/// 与间距），差异只通过 [subtitle]/[meta]/[extra] 传进来。封面高度默认按
/// [kCoverAspect] 从宽度算出（96×132），与列表封面保持同一个比例。
class DetailCoverHeader extends StatelessWidget {
  const DetailCoverHeader({
    super.key,
    required this.cover,
    required this.title,
    this.coverFallback = '',
    this.subtitle = '',
    this.meta = '',
    this.extra,
    this.coverWidth = 96,
    double? coverHeight,
  }) : coverHeight = coverHeight ?? coverWidth * kCoverAspect;

  final String cover;
  final String coverFallback;
  final String title;

  /// 副标题：小说是作者、短剧是「全 N 集」。
  final String subtitle;

  /// 元信息一行：小说是「分类 · 状态 · 字数」，短剧是「分类 · 播放量」。
  final String meta;

  /// 附加区域：小说放评分/在读/更新至，短剧可为空。
  final Widget? extra;

  final double coverWidth;
  final double coverHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const gutter = detailGutter;

    return Container(
      padding: EdgeInsets.fromLTRB(
        gutter + 4,
        MediaQuery.paddingOf(context).top + 8,
        gutter + 4,
        gutter + 4,
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
            width: coverWidth,
            height: coverHeight,
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
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
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
                if (extra != null) ...[
                  const SizedBox(height: 8),
                  extra!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 简介 + 标签卡片。简介默认折叠 [collapsedLines] 行，超出才给展开/收起。
class DetailIntroCard extends StatelessWidget {
  const DetailIntroCard({
    super.key,
    required this.intro,
    this.tags = const [],
    this.collapsedLines = 4,
  });

  final String intro;
  final List<String> tags;
  final int collapsedLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = intro.trim();
    return Card(
      margin: const EdgeInsets.fromLTRB(detailGutter, 6, detailGutter, 0),
      child: Padding(
        padding: const EdgeInsets.all(detailGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '简介',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ExpandableIntro(
              text: text.isEmpty ? '暂无简介' : text,
              collapsedLines: collapsedLines,
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              DetailTagWrap(tags: tags),
            ],
          ],
        ),
      ),
    );
  }
}

/// 可展开/收起的长文本：默认折叠 [collapsedLines] 行。
///
/// 用 TextPainter 量一次是否超出：没超出就不显示「展开」，避免短简介下面挂
/// 一个点了没反应的按钮。
class ExpandableIntro extends StatefulWidget {
  const ExpandableIntro({
    super.key,
    required this.text,
    this.collapsedLines = 4,
  });

  final String text;
  final int collapsedLines;

  @override
  State<ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<ExpandableIntro> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ExpandableIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从 preview 切到接口数据后简介可能变长/变短，回到折叠态重新判断。
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var style = theme.textTheme.bodyMedium?.copyWith(height: 1.6);
    // 系统开了粗体时 TextPainter 与 Text 的样式必须一致，否则测量结果失真。
    if (MediaQuery.boldTextOf(context)) {
      style = (style ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: widget.collapsedLines,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                maxLines: _expanded ? null : widget.collapsedLines,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.primary,
                  ),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 区块标题行：左边标题，右边可选操作（如「共 N 章 · 查看全部」）。
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      detailGutter,
      detailGutter,
      detailGutter,
      4,
    ),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // trailing 靠右但不抢占固定宽度：窄屏/大字号下让它自己省略，
          // 而不是把标题挤没。
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// 标签小圆角 pill。Material 的 [Chip] 自带 48dp 点击区，一屏标签会撑出
/// 一大块空白，这里只画视觉（标签本身不可点）。
class DetailTagChip extends StatelessWidget {
  const DetailTagChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一组标签：自动换行。
class DetailTagWrap extends StatelessWidget {
  const DetailTagWrap({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final tag in tags) DetailTagChip(label: tag)],
    );
  }
}
