import 'package:flutter/material.dart';

import '../../../data/models/chapter.dart';

/// 打开「选集」底部弹层，返回被选中的集下标（取消返回 null）。
///
/// 与阅读器的目录弹层同款交互：底部弹层 + 网格快速跳集。集数只显示数字
/// （不写「第 x 集」），一行放 6 个，长剧也能两三下翻到目标集。
Future<int?> showEpisodePickerSheet(
  BuildContext context, {
  required List<Chapter> episodes,
  required int currentIndex,
  required String seriesTitle,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.7,
      child: _EpisodePickerBody(
        episodes: episodes,
        currentIndex: currentIndex,
        seriesTitle: seriesTitle,
      ),
    ),
  );
}

class _EpisodePickerBody extends StatelessWidget {
  const _EpisodePickerBody({
    required this.episodes,
    required this.currentIndex,
    required this.seriesTitle,
  });

  final List<Chapter> episodes;
  final int currentIndex;
  final String seriesTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
          child: Row(
            children: [
              Text(
                '选集',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '共 ${episodes.length} 集 · $seriesTitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭选集',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 44,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final selected = index == currentIndex;
              final label = Text(
                '${index + 1}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              );
              void onTap() => Navigator.of(context).pop(index);
              return selected
                  ? FilledButton(
                      onPressed: onTap,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: label,
                    )
                  : OutlinedButton(
                      onPressed: onTap,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: label,
                    );
            },
          ),
        ),
      ],
    );
  }
}
