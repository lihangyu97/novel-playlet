import 'package:flutter/material.dart';

import '../../app/widgets/app_bottom_sheet.dart';
import '../../data/models/chapter.dart';

/// 打开全部目录的底部弹层；返回被点中的章节（取消返回 null）。
Future<Chapter?> showDetailDirectorySheet(
  BuildContext context, {
  required List<Chapter> chapters,
  int? currentIndex,
}) {
  return showAppBottomSheet<Chapter>(
    context: context,
    builder: (_) => _DirectorySheetBody(
      chapters: chapters,
      currentIndex: currentIndex,
    ),
  );
}

class _DirectorySheetBody extends StatelessWidget {
  const _DirectorySheetBody({required this.chapters, this.currentIndex});

  final List<Chapter> chapters;
  final int? currentIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBottomSheet(
      title: '目录',
      subtitle: '共 ${chapters.length} 章',
      heightFactor: 0.85,
      closeTooltip: '关闭目录',
      child: chapters.isEmpty
          ? Center(
              child: Text(
                '暂无目录',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: chapters.length,
              itemBuilder: (context, index) {
                final chapter = chapters[index];
                // 目录已摊平，卷名挂在每条上；只在卷首插一次卷标题。
                final showVolume =
                    chapter.volumeName.isNotEmpty &&
                    (index == 0 ||
                        chapters[index - 1].volumeName != chapter.volumeName);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showVolume)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                        child: Text(
                          chapter.volumeName,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    _SheetChapterTile(
                      chapter: chapter,
                      current: chapter.index == currentIndex,
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _SheetChapterTile extends StatelessWidget {
  const _SheetChapterTile({required this.chapter, this.current = false});

  final Chapter chapter;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = chapter.title.isNotEmpty
        ? chapter.title
        : '第${chapter.index + 1}章';
    return InkWell(
      onTap: () => Navigator.of(context).pop(chapter),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
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
