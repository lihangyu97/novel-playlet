import 'package:flutter/material.dart';

import '../../data/models/chapter.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';

/// 目录弹层：全章节列表 + 右侧常驻可拖动滚动条。
///
/// 小说详情「查看全部」和阅读器「目录」共用这一套（以前各写了一份）：
/// - 每行高度固定，打开时按行高直接算出当前章偏移，不用等逐项布局；
/// - 当前章：左侧主色竖条 + 淡色底 + 行尾「当前 / 读到这里」；
/// - 右侧常驻一条可按住上下拖动的滚动条，上千章也能快速定位；
/// - 详情页按 `volumeName` 插卷标题（阅读器不插，保持原有观感）。
class ChapterDirectorySheet extends StatefulWidget {
  const ChapterDirectorySheet({
    super.key,
    required this.chapters,
    required this.onSelected,
    this.currentIndex,
    this.showVolumes = false,
    this.currentLabel = '当前',
    this.heightFactor = 0.72,
    this.backgroundColor,
    this.foregroundColor,
  });

  /// 单行章节高度（固定，滚动定位按它累加）。
  static const double chapterExtent = 52;

  /// 卷标题行高度（固定，同样参与滚动定位）。
  static const double volumeExtent = 40;

  final List<Chapter> chapters;

  /// 被点中的章节在 [chapters] 里的下标。
  final ValueChanged<int> onSelected;

  /// 当前章在整本目录里的序号（`Chapter.index`）；null = 不高亮、不定位。
  final int? currentIndex;

  /// 是否按 `volumeName` 插入卷标题。
  final bool showVolumes;

  /// 当前章行尾的文案。阅读器是「当前」，详情页是「读到这里」。
  final String currentLabel;

  /// 弹层高度占屏幕比例。
  final double heightFactor;

  /// 弹层底色 / 前景色（阅读器按纸色传，详情页用 App 主题）。
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  State<ChapterDirectorySheet> createState() => _ChapterDirectorySheetState();
}

class _ChapterDirectorySheetState extends State<ChapterDirectorySheet> {
  late final List<_DirectoryEntry> _entries = _buildEntries();
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: _initialOffset(),
  );

  @override
  void initState() {
    super.initState();
    // 短目录（内容不够一屏）时算出来的偏移可能超过可滚动范围，首帧后夹一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if (_controller.offset > max) _controller.jumpTo(max);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = widget.foregroundColor ?? scheme.onSurface;
    return AppBottomSheet(
      title: '目录',
      subtitle: '共 ${widget.chapters.length} 章',
      // 0.72 屏高：比设置弹层高，目录能多露几行。
      heightFactor: widget.heightFactor,
      backgroundColor: widget.backgroundColor,
      foregroundColor: foreground,
      closeTooltip: '关闭目录',
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: true,
        thickness: 5,
        radius: const Radius.circular(3),
        child: ListView.builder(
          controller: _controller,
          itemCount: _entries.length,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final volume = entry.volume;
            if (volume != null) {
              return _VolumeRow(name: volume);
            }
            return _ChapterRow(
              chapter: entry.chapter!,
              current: entry.chapter!.index == widget.currentIndex,
              currentLabel: widget.currentLabel,
              foreground: foreground,
              onTap: () => widget.onSelected(entry.position),
            );
          },
        ),
      ),
    );
  }

  List<_DirectoryEntry> _buildEntries() {
    final entries = <_DirectoryEntry>[];
    final chapters = widget.chapters;
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      // 目录已摊平，卷名挂在每条上；只在卷首插一次卷标题。
      if (widget.showVolumes &&
          chapter.volumeName.isNotEmpty &&
          (i == 0 || chapters[i - 1].volumeName != chapter.volumeName)) {
        entries.add(_DirectoryEntry.volume(chapter.volumeName, i));
      }
      entries.add(_DirectoryEntry.chapter(chapter, i));
    }
    return entries;
  }

  /// 当前章到列表顶部的距离；找不到当前章就从顶部开始。
  double _initialOffset() {
    final currentIndex = widget.currentIndex;
    if (currentIndex == null) return 0;
    var offset = 0.0;
    var found = false;
    for (final entry in _entries) {
      if (entry.chapter?.index == currentIndex) {
        found = true;
        break;
      }
      offset += entry.extent;
    }
    if (!found) return 0;
    // 往上留一点：当前章不要正好贴弹层标题区。
    return (offset - 120).clamp(0.0, double.infinity);
  }
}

/// 摊平后的列表项：章节或卷标题。`position` 是章节在原始目录里的下标。
class _DirectoryEntry {
  const _DirectoryEntry.chapter(this.chapter, this.position) : volume = null;
  const _DirectoryEntry.volume(this.volume, this.position) : chapter = null;

  final Chapter? chapter;
  final String? volume;
  final int position;

  double get extent => chapter != null
      ? ChapterDirectorySheet.chapterExtent
      : ChapterDirectorySheet.volumeExtent;
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.current,
    required this.currentLabel,
    required this.foreground,
    required this.onTap,
  });

  final Chapter chapter;
  final bool current;
  final String currentLabel;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.primary;
    final title = chapter.title.isEmpty
        ? '第 ${chapter.index + 1} 章'
        : chapter.title;
    return SizedBox(
      height: ChapterDirectorySheet.chapterExtent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: current
                ? highlight.withValues(alpha: 0.07)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: current ? highlight : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: current
                        ? context.appWeight(FontWeight.w600)
                        : context.appWeight(FontWeight.w400),
                    color: current
                        ? highlight
                        : foreground.withValues(alpha: 0.82),
                  ),
                ),
              ),
              if (current)
                Text(
                  currentLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: foreground.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChapterDirectorySheet.volumeExtent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: context.appWeight(FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
