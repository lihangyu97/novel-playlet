import 'package:flutter/material.dart';

import 'detail_style.dart';

/// 简介 + 标签卡片。简介默认 4 行、超出才给展开/收起。
class DetailIntroSection extends StatelessWidget {
  const DetailIntroSection({
    super.key,
    required this.intro,
    required this.tags,
  });

  final String intro;
  final List<String> tags;

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
            _ExpandableIntro(text: text.isEmpty ? '暂无简介' : text),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in tags) DetailTagChip(label: tag)],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 默认折叠 4 行。用 TextPainter 量一次是否超出：没超出就不显示「展开」，
/// 避免短简介下面挂一个点了没反应的按钮。
class _ExpandableIntro extends StatefulWidget {
  const _ExpandableIntro({required this.text});

  final String text;

  @override
  State<_ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<_ExpandableIntro> {
  static const _collapsedLines = 4;

  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _ExpandableIntro oldWidget) {
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
          maxLines: _collapsedLines,
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
                maxLines: _expanded ? null : _collapsedLines,
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
