import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../data/models/chapter.dart';
import 'reader_pagination.dart';
import 'reader_settings.dart';

/// 渲染一页正文。
///
/// 每段只裁剪、不重新排版：整段 Text.rich 用与测量时完全相同的宽度/样式/
/// 缩放画出来，再按行偏移把它上移到片段位置。这样断行永远和 TextPainter
/// 的测量一致，不会出现页尾文字被切掉半行。
class ReaderPageContent extends StatelessWidget {
  const ReaderPageContent({
    super.key,
    required this.page,
    required this.textStyle,
    required this.textScaler,
    required this.contentWidth,
    required this.horizontalPadding,
    this.onBubbleTap,
  });

  final ReaderPage page;
  final TextStyle textStyle;
  final TextScaler textScaler;

  /// 可读区宽度（不含左右内边距），首行缩进按它计算。
  final double contentWidth;
  final double horizontalPadding;

  /// 点段评气泡：回调段落 id，由阅读页打开该段的评论面板。
  final void Function(int paraIndex)? onBubbleTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Stack(
        children: [
          for (final fragment in page.fragments) _buildFragment(fragment),
        ],
      ),
    );
  }

  Widget _buildFragment(ReaderFragment fragment) {
    // 与分页测量共用同一个 span 构建函数：首行缩进 / 段评气泡的占位度量
    // 在测量与渲染两侧完全一致，不能各自实现一套。
    final block = fragment.block;
    final paraIndex = block.paraIndex;
    final paragraph = buildReaderParagraphSpan(
      text: block.text,
      style: textStyle,
      width: contentWidth,
      textScaler: textScaler,
      bubbleCount: block.bubbleCount,
      bubbleVariant: block.bubbleVariant,
      onBubbleTap: paraIndex == null || onBubbleTap == null
          ? null
          : () => onBubbleTap!(paraIndex),
    );
    return Positioned(
      top: fragment.top,
      left: 0,
      right: 0,
      height: fragment.height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: fragment.block.height,
          maxHeight: fragment.block.height,
          child: Transform.translate(
            offset: Offset(0, -fragment.sourceTop),
            child: Text.rich(
              paragraph.span,
              style: textStyle,
              textAlign: TextAlign.justify,
              textDirection: TextDirection.ltr,
              textScaler: textScaler,
              textHeightBehavior: readerTextHeightBehavior,
              textWidthBasis: TextWidthBasis.parent,
              locale: const Locale('zh', 'CN'),
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具栏顶部：返回 + 书名 + 右侧「书架状态 / 缓存状态」两个文本动作。
///
/// 书名与右侧状态动作同字号、占返回键与动作之间的剩余宽度，超宽省略；章节名
/// 在底部常驻信息条里一直可见，不在顶部重复。
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    this.topInset = 0,
    required this.background,
    required this.foreground,
    required this.onBack,
    this.title = '',
    required this.shelfLabel,
    this.onShelfTap,
    required this.cacheLabel,
    this.onCacheTap,
  });

  /// 状态栏高度：工具栏贴屏幕顶，背景要铺到状态栏后面。
  final double topInset;
  final Color background;
  final Color foreground;
  final VoidCallback onBack;

  /// 书名：和右侧状态动作同字号，占剩余宽度、超宽省略（不挤压右侧按钮）。
  final String title;

  /// 左：`加入书架`（可点）或 `已在书架`（只读状态，点击无响应）。
  final String shelfLabel;
  final VoidCallback? onShelfTap;

  /// 右：`缓存小说`（可点开始下载）/ `缓存中` / `已缓存`（点击进缓存中心）。
  final String cacheLabel;
  final VoidCallback? onCacheTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: Container(
        height: 52 + topInset,
        padding: EdgeInsets.only(top: topInset),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: foreground.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: onBack,
              tooltip: '返回',
              color: foreground,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            ),
            // 书名占返回键与右侧动作之间的全部剩余宽度：右侧动作宽度固定，
            // 书名再长也只会自己省略，不会把按钮挤出屏幕。
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _actionFontSize,
                    height: 1.2,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ),
            ),
            _ReaderTextAction(
              label: shelfLabel,
              color: foreground,
              onTap: onShelfTap,
            ),
            _ReaderTextAction(
              label: cacheLabel,
              color: foreground,
              onTap: onCacheTap,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// 顶部状态动作字号：13 在真机上偏小、20 又太大，取 16 兼顾易读与克制的层级。
const double _actionFontSize = 16;

/// 顶部文字动作：有回调才是按钮，没回调只作状态文案（不可点、压暗一档）。
class _ReaderTextAction extends StatelessWidget {
  const _ReaderTextAction({
    required this.label,
    required this.color,
    this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    if (onTap == null) {
      // 状态文案不接收点击：`已在书架`/`已缓存` 点击必须无响应。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            fontSize: _actionFontSize,
            height: 1.2,
            // 状态文字要读得清：0.55 在纸色/夜间底上只有 ~3.4:1，低于 WCAG AA。
            color: color.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // 从主题 labelLarge 派生：textStyle 会整体替换按钮默认文字样式，
        // 直接给 const TextStyle 会丢掉主题字体（自定义字体下中文变豆腐块）。
        textStyle: Theme.of(context).textTheme.labelLarge
            ?.copyWith(fontSize: _actionFontSize, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}

/// 工具栏底部：目录 / 评论 / 日间·夜间 / 设置。
///
/// 上一章/下一章不再占按钮位：点击正文左右分区、章边界继续滑动、目录跳章都
/// 能切章；空出来的位置给日间/夜间切换。
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({
    super.key,
    this.bottomInset = 0,
    required this.background,
    required this.foreground,
    required this.isNight,
    required this.onDirectory,
    required this.onToggleDayNight,
    required this.onSettings,
    this.onComments,
  });

  /// Home 指示条高度：工具栏贴屏幕底，背景铺到安全区后面。
  final double bottomInset;

  final Color background;
  final Color foreground;

  /// 当前是不是夜间纸：决定切换按钮显示「日间」还是「夜间」。
  final bool isNight;

  final VoidCallback onDirectory;
  final VoidCallback onToggleDayNight;
  final VoidCallback onSettings;
  final VoidCallback? onComments;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: foreground.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
        ),
        padding: EdgeInsets.only(bottom: 6 + bottomInset),
        child: Row(
          children: [
            _ReaderToolButton(
              icon: Icons.format_list_bulleted_rounded,
              label: '目录',
              color: foreground,
              onTap: onDirectory,
            ),
            _ReaderToolButton(
              icon: Icons.forum_outlined,
              label: '评论',
              color: foreground,
              onTap: onComments,
            ),
            _ReaderToolButton(
              icon: isNight
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              label: isNight ? '日间' : '夜间',
              color: foreground,
              onTap: onToggleDayNight,
            ),
            _ReaderToolButton(
              icon: Icons.text_fields_rounded,
              label: '设置',
              color: foreground,
              onTap: onSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReaderToolButton extends StatelessWidget {
  const _ReaderToolButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = onTap == null ? color.withValues(alpha: 0.3) : color;
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, height: 1.1, color: tint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 切章加载时浮在旧正文上的小提示：不做全屏 Loading，避免闪白。
class ReaderLoadingPill extends StatelessWidget {
  const ReaderLoadingPill({
    super.key,
    required this.message,
    required this.foreground,
  });

  final String message;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(foreground),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            message,
            style: TextStyle(
              fontSize: 11.5,
              color: foreground.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// 阅读设置弹层：字号、行距、底色。
class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final controller = ref.read(readerSettingsProvider.notifier);
    final paper = settings.paper;
    final foreground = paper.foreground;
    final muted = foreground.withValues(alpha: 0.55);
    // 弹层由阅读页用「纸色对应的 Theme」包着（reader_page._readerTheme），
    // 所以这里的 primary 已按纸色明暗派生，在纸色/夜间底上对比度足够；
    // 不能直接用 AppTheme.accentOf（raw seed）——用户选近白/近黑主题色时
    // 滑块和描边会彻底看不见。
    final highlight = Theme.of(context).colorScheme.primary;
    // 弹层要一直铺到屏幕底：把 Home 指示条高度做成容器内部的 padding，
    // 而不是 SafeArea 在外层留白。否则最底部会露出弹层外的灰色横条。
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: paper.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + bottomInset),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: highlight,
          inactiveTrackColor: foreground.withValues(alpha: 0.14),
          thumbColor: highlight,
          overlayColor: highlight.withValues(alpha: 0.12),
          trackHeight: 2.5,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '阅读设置',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
            const SizedBox(height: 4),
            _SettingRow(
              label: '字号',
              value: '${settings.fontSize.round()}',
              color: muted,
              child: Slider(
                min: ReaderSettingsController.minFontSize,
                max: ReaderSettingsController.maxFontSize,
                divisions: 15,
                value: settings.fontSize,
                label: '${settings.fontSize.round()}',
                onChanged: controller.setFontSize,
              ),
            ),
            _SettingRow(
              label: '行距',
              value: settings.lineHeight.toStringAsFixed(2),
              color: muted,
              child: Slider(
                min: ReaderSettingsController.minLineHeight,
                max: ReaderSettingsController.maxLineHeight,
                divisions: 14,
                value: settings.lineHeight,
                label: settings.lineHeight.toStringAsFixed(2),
                onChanged: controller.setLineHeight,
              ),
            ),
            const SizedBox(height: 6),
            Text('底色', style: TextStyle(fontSize: 13, color: muted)),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final option in ReaderPaper.values)
                  Expanded(
                    child: _PaperOption(
                      option: option,
                      selected: option == paper,
                      foreground: foreground,
                      onTap: () => controller.setPaper(option),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '段评气泡',
                        style: TextStyle(fontSize: 13, color: foreground),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '关闭只隐藏段尾气泡，章末评论仍在',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.showBubbles,
                  onChanged: controller.setShowBubbles,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.value,
    required this.color,
    required this.child,
  });

  final String label;
  final String value;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: TextStyle(fontSize: 13, color: color)),
        ),
        Expanded(child: child),
        SizedBox(
          width: 34,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ),
      ],
    );
  }
}

class _PaperOption extends StatelessWidget {
  const _PaperOption({
    required this.option,
    required this.selected,
    required this.foreground,
    required this.onTap,
  });

  final ReaderPaper option;
  final bool selected;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // primary 按纸色明暗派生，选中态文字/边框都用它：比 raw seed 稳，
    // 用户选近白/近黑主题色时也不会消失。
    final highlight = Theme.of(context).colorScheme.primary;
    return InkResponse(
      onTap: onTap,
      radius: 34,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: option.background,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? highlight : foreground.withValues(alpha: 0.2),
                width: selected ? 2 : 0.8,
              ),
            ),
            child: selected
                ? Icon(Icons.check_rounded, size: 18, color: option.foreground)
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            option.label,
            style: TextStyle(
              fontSize: 11.5,
              color: selected ? highlight : foreground.withValues(alpha: 0.6),
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// 目录弹层：全章节列表，当前章高亮并自动滚到可视区域。
class ReaderDirectorySheet extends StatefulWidget {
  const ReaderDirectorySheet({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.background,
    required this.foreground,
    required this.onSelected,
  });

  final List<Chapter> chapters;
  final int currentIndex;
  final Color background;
  final Color foreground;
  final ValueChanged<int> onSelected;

  @override
  State<ReaderDirectorySheet> createState() => _ReaderDirectorySheetState();
}

class _ReaderDirectorySheetState extends State<ReaderDirectorySheet> {
  static const double _itemExtent = 52;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 列表首帧布局完再滚，才能拿到 maxScrollExtent 做夹取。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = widget.currentIndex * _itemExtent - 120;
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = widget.foreground.withValues(alpha: 0.55);
    // 背景铺到屏幕底，内容让出 Home 指示条；这样列表最后一项不会被挡住，
    // 也不会出现"容器底边没铺满"的灰色空条。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Container(
        decoration: BoxDecoration(
          color: widget.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
              child: Row(
                children: [
                  Text(
                    '目录',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: widget.foreground,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '共 ${widget.chapters.length} 章',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                    color: widget.foreground,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: widget.foreground.withValues(alpha: 0.08),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemExtent: _itemExtent,
                itemCount: widget.chapters.length,
                itemBuilder: (context, index) => _buildItem(context, index),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final chapter = widget.chapters[index];
    final selected = index == widget.currentIndex;
    final title = chapter.title.isEmpty ? '第 ${index + 1} 章' : chapter.title;
    final highlight = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => widget.onSelected(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: selected
              ? highlight.withValues(alpha: 0.07)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? highlight : Colors.transparent,
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
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? highlight
                      : widget.foreground.withValues(alpha: 0.82),
                ),
              ),
            ),
            if (selected)
              Text(
                '当前',
                style: TextStyle(
                  fontSize: 11,
                  color: widget.foreground.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
