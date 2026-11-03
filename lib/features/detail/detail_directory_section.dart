import 'package:flutter/material.dart';

import '../../data/models/chapter.dart';
import 'detail_style.dart';

/// 目录卡片：先露前 10 章，右上角「共 N 章 · 查看全部」进全部目录弹层。
class DetailDirectorySection extends StatelessWidget {
  const DetailDirectorySection({
    super.key,
    required this.chapters,
    required this.onOpenChapter,
    required this.onOpenAll,
    this.currentIndex,
  });

  /// 已被阅读进度指针（0 基）指到的章节，用来标「读到这里」。
  final int? currentIndex;
  final List<Chapter> chapters;
  final ValueChanged<Chapter> onOpenChapter;
  final VoidCallback onOpenAll;

  static const _previewCount = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = chapters.take(_previewCount).toList(growable: false);

    return Card(
      margin: const EdgeInsets.fromLTRB(detailGutter, 6, detailGutter, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailSectionHeader(
            title: '目录',
            padding: const EdgeInsets.fromLTRB(
              detailGutter,
              detailGutter,
              detailGutter - 8,
              4,
            ),
            trailing: chapters.isEmpty
                ? null
                : TextButton(
                    onPressed: onOpenAll,
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.primary,
                    ),
                    child: Text(
                      '共 ${chapters.length} 章 · 查看全部',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
          ),
          if (preview.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                detailGutter,
                4,
                detailGutter,
                detailGutter,
              ),
              child: Text(
                '暂无目录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (var i = 0; i < preview.length; i++) ...[
              _ChapterRow(
                key: ValueKey(preview[i].id),
                chapter: preview[i],
                current: preview[i].index == currentIndex,
                onTap: () => onOpenChapter(preview[i]),
              ),
              if (i < preview.length - 1)
                const Divider(
                  height: 1,
                  indent: detailGutter,
                  endIndent: detailGutter,
                ),
            ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    super.key,
    required this.chapter,
    required this.onTap,
    this.current = false,
  });

  final Chapter chapter;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = chapter.title.isNotEmpty
        ? chapter.title
        : '第${chapter.index + 1}章';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: detailGutter,
          vertical: 12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: current ? scheme.primary : scheme.onSurface,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (current) ...[
              const SizedBox(width: 8),
              Text(
                '读到这里',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
