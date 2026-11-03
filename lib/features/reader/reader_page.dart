import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter_content.dart';
import 'reader_controller.dart';
import 'reader_pagination.dart';
import 'reader_settings.dart';
import 'reader_widgets.dart';

/// 小说阅读页：分页正文 + 点击分区 + 工具栏 + 设置/目录弹层。
///
/// 分页是"测量一次、缓存起来"的：只有在正文、字号、行距、可读区尺寸或
/// 系统字体缩放变化时才重排，普通重建（工具栏、页码变化）直接复用结果。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.args});

  final ReaderArgs args;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

/// 换章时落在新章的哪一页：点右侧翻到章尾继续读，应该进下一章第 0 页；
/// 点左侧回上一章，应该落在上一章最后一页，符合"往回翻"的直觉。
enum _ChapterEntry { firstPage, lastPage }

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const double _horizontalPadding = 20;
  // 页码只在工具栏打开时显示；常驻页眉/页脚已移除，正文占满可读区。
  final ValueNotifier<int> _pageCount = ValueNotifier<int>(1);
  static const Duration _pageTurnDuration = Duration(milliseconds: 220);
  static const Duration _toolbarDuration = Duration(milliseconds: 200);

  PageController _pageController = PageController(keepPage: false);
  ReaderPagination? _pagination;
  _PaginationKey? _paginationKey;
  int _pageIndex = 0;
  bool _toolbarVisible = false;
  bool _turning = false;
  _ChapterEntry? _pendingEntry;

  @override
  void dispose() {
    _pageController.dispose();
    _pageCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = readerSessionProvider(widget.args);
    final session = ref.watch(provider);
    final settings = ref.watch(readerSettingsProvider);
    final controller = ref.read(provider.notifier);
    final paper = settings.paper;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle(paper),
      child: Scaffold(
        backgroundColor: paper.background,
        // 工具栏不能放在 SafeArea 里：收起时 AnimatedSlide 只平移自身高度，
        // 会正好停在状态栏/Home 指示条那条里（真机实测"没隐藏干净"）。
        // 正文留在 SafeArea 内，工具栏贴屏幕边缘、自己内部补安全区 padding。
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTap,
                  child: _buildBody(session, settings, controller),
                ),
              ),
            ),
            // 工具栏打开时压暗正文，让浮层上的文字更清楚；本身不接收点击，
            // 点击穿透到正文的手势识别器，交给 _handleTap 收起工具栏。
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _toolbarVisible ? 1 : 0,
                  duration: _toolbarDuration,
                  child: const ColoredBox(color: Color(0x33000000)),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopBar(session, settings),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomBar(session, settings, controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    ReaderSessionState session,
    ReaderSettings settings,
    ReaderController controller,
  ) {
    final paper = settings.paper;
    final error = session.error;
    if (error != null) {
      return _buildStatus(
        paper,
        ErrorView(message: error, onRetry: controller.retry),
      );
    }
    if (!session.hasChapters) {
      return session.loading
          ? _buildStatus(paper, const LoadingView(label: '正在加载目录…'))
          : _buildStatus(
              paper,
              const EmptyView(message: '目录为空', icon: Icons.menu_book_rounded),
            );
    }
    final content = session.content;
    if (content == null) {
      return _buildStatus(paper, const LoadingView(label: '正在加载正文…'));
    }
    if (content.isEmpty) {
      return _buildStatus(paper, _buildEmptyChapter(session, controller));
    }
    return _buildPagedContent(session, settings, content);
  }

  /// 共享状态视图在夜间底色下要换一套亮色 scheme，否则文字会看不清。
  Widget _buildStatus(ReaderPaper paper, Widget child) {
    return ColoredBox(
      color: paper.background,
      child: Theme(data: _readerTheme(paper), child: child),
    );
  }

  ThemeData _readerTheme(ReaderPaper paper) {
    final brightness = paper == ReaderPaper.night
        ? Brightness.dark
        : Brightness.light;
    return Theme.of(context).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppTheme.accent,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: paper.background,
    );
  }

  Widget _buildEmptyChapter(
    ReaderSessionState session,
    ReaderController controller,
  ) {
    return Column(
      children: [
        const Expanded(
          child: EmptyView(message: '本章暂无正文', icon: Icons.article_outlined),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: session.hasPrevious
                    ? () => controller.previousChapter()
                    : null,
                child: const Text('上一章'),
              ),
              const SizedBox(width: 16),
              OutlinedButton(
                onPressed: session.hasNext
                    ? () => controller.nextChapter()
                    : null,
                child: const Text('下一章'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPagedContent(
    ReaderSessionState session,
    ReaderSettings settings,
    ChapterContent content,
  ) {
    final paper = settings.paper;
    final foreground = paper.foreground;
    final textStyle = _readerTextStyle(settings, foreground);
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - _horizontalPadding * 2;
        final pageHeight = constraints.maxHeight;
        final pagination = contentWidth <= 0 || pageHeight <= 0
            ? null
            : _obtainPagination(
                content: content,
                settings: settings,
                textScaler: textScaler,
                width: contentWidth,
                height: pageHeight,
              );
        if (pagination == null || pagination.pages.isEmpty) {
          return _buildStatus(
            paper,
            const EmptyView(message: '本章暂无正文', icon: Icons.article_outlined),
          );
        }
        final pages = pagination.pages;
        if (_pageCount.value != pages.length) {
          // 分页结果在 build 里产生，通知要放到帧后再发，避免 build 期回调。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _pageCount.value != pages.length) {
              _pageCount.value = pages.length;
            }
          });
        }
        return Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                key: ValueKey<String>(
                  'reader-pager-${pagination.chapterId}',
                ),
                controller: _pageController,
                itemCount: pages.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) => RepaintBoundary(
                  child: ReaderPageContent(
                    page: pages[index],
                    textStyle: textStyle,
                    textScaler: textScaler,
                    horizontalPadding: _horizontalPadding,
                  ),
                ),
              ),
            ),
            if (session.loading)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: ReaderLoadingPill(
                    message: '正在加载第 ${session.index + 1} 章…',
                    foreground: foreground,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 正文样式：`inherit: false` 是关键——Text 默认会和 DefaultTextStyle 合并
  /// （例如 leadingDistribution），而 TextPainter 不合并，两者行高会不一致。
  /// 这里用固定样式同时喂给测量与渲染，保证断行绝对一致。
  TextStyle _readerTextStyle(ReaderSettings settings, Color color) {
    return AppTheme.readerText(
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      color: color,
    ).copyWith(inherit: false);
  }

  /// 拿分页结果；输入没变就直接返回缓存，绝不每帧重排。
  ReaderPagination _obtainPagination({
    required ChapterContent content,
    required ReaderSettings settings,
    required TextScaler textScaler,
    required double width,
    required double height,
  }) {
    final key = _PaginationKey(
      content: content,
      width: width,
      height: height,
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      textScale: textScaler.scale(16),
    );
    final cached = _pagination;
    if (cached != null && _paginationKey == key) return cached;

    final sameChapter = cached != null && cached.chapterId == content.id;
    // 重排前记下当前页首段，重排后回到包含它的那一页。
    final anchorBlock = sameChapter && cached.pages.isNotEmpty
        ? cached.blockAtPage(_pageIndex)
        : null;
    final pagination = ReaderPagination.build(
      chapterId: content.id,
      paragraphs: content.paragraphs,
      spec: ReaderLayoutSpec(
        width: width,
        height: height,
        textScaler: textScaler,
        bodyStyle: _readerTextStyle(settings, Colors.black),
        paragraphSpacing: settings.fontSize * 0.55,
      ),
    );
    _pagination = pagination;
    _paginationKey = key;

    if (cached == null) {
      _pageIndex = 0;
    } else if (!sameChapter) {
      // 换章：新章从指定页开始，同时换掉 PageController，避免旧滚动位置
      // 让新的 PageView 先停在中途再跳回来（那会闪一下）。
      final entry = _pendingEntry ?? _ChapterEntry.firstPage;
      _pendingEntry = null;
      final target =
          entry == _ChapterEntry.lastPage && pagination.pages.isNotEmpty
          ? pagination.pages.length - 1
          : 0;
      _pageIndex = target;
      _restartPageController(target);
    } else {
      final anchor = anchorBlock;
      final target = anchor == null ? 0 : pagination.pageIndexForBlock(anchor);
      _pageIndex = target;
      _scheduleJump(target);
    }
    return pagination;
  }

  /// 换掉 PageController 后旧的滚动位置就作废了；等这一帧把旧 PageView
  /// 卸载（detach 掉 position）之后再释放旧控制器。
  void _restartPageController(int initialPage) {
    final retired = _pageController;
    _pageController = PageController(initialPage: initialPage, keepPage: false);
    WidgetsBinding.instance.addPostFrameCallback((_) => retired.dispose());
  }

  void _scheduleJump(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      // 排队的跳页可能已经过时（用户自己滑走了），以最新页码为准。
      if (_pageIndex != page) return;
      if (_pageController.page?.round() == page) return;
      _pageController.jumpToPage(page);
    });
  }

  void _onPageChanged(int index) {
    if (!mounted || index == _pageIndex) return;
    setState(() => _pageIndex = index);
  }

  void _handleTap(TapUpDetails details) {
    if (_toolbarVisible) {
      _hideToolbar();
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final dx = details.localPosition.dx;
    if (dx < width / 3) {
      unawaited(_turnPage(-1));
    } else if (dx > width * 2 / 3) {
      unawaited(_turnPage(1));
    } else {
      setState(() => _toolbarVisible = true);
    }
  }

  Future<void> _turnPage(int direction) async {
    final pagination = _pagination;
    if (pagination == null || pagination.pages.isEmpty || _turning) return;
    final session = ref.read(readerSessionProvider(widget.args));
    // 正在换章时页码还属于上一章，按它翻页会一次跳过两章。
    if (session.loading || session.index != session.contentIndex) return;
    final controller = ref.read(readerSessionProvider(widget.args).notifier);
    final target = _pageIndex + direction;

    if (target < 0) {
      if (!session.hasPrevious) return;
      _pendingEntry = _ChapterEntry.lastPage;
      await controller.previousChapter();
      return;
    }
    if (target >= pagination.pages.length) {
      if (!session.hasNext) return;
      _pendingEntry = _ChapterEntry.firstPage;
      await controller.nextChapter();
      return;
    }
    _turning = true;
    try {
      await _pageController.animateToPage(
        target,
        duration: _pageTurnDuration,
        curve: Curves.easeOutCubic,
      );
    } finally {
      _turning = false;
    }
  }

  void _hideToolbar() {
    if (!_toolbarVisible) return;
    setState(() => _toolbarVisible = false);
  }

  void _onBack() {
    Navigator.of(context).maybePop();
  }

  Widget _buildTopBar(ReaderSessionState session, ReaderSettings settings) {
    final paper = settings.paper;
    final title = session.bookTitle.isNotEmpty
        ? session.bookTitle
        : (session.displayedChapter?.title ?? '');
    return IgnorePointer(
      ignoring: !_toolbarVisible,
      child: AnimatedSlide(
        offset: _toolbarVisible ? Offset.zero : const Offset(0, -1.02),
        duration: _toolbarDuration,
        curve: Curves.easeOutCubic,
        child: ReaderTopBar(
          topInset: MediaQuery.paddingOf(context).top,
          title: title,
          subtitle: session.displayedChapter?.title ?? '',
          background: paper.background,
          foreground: paper.foreground,
          onBack: _onBack,
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    ReaderSessionState session,
    ReaderSettings settings,
    ReaderController controller,
  ) {
    final paper = settings.paper;
    return IgnorePointer(
      ignoring: !_toolbarVisible,
      child: AnimatedSlide(
        offset: _toolbarVisible ? Offset.zero : const Offset(0, 1.02),
        duration: _toolbarDuration,
        curve: Curves.easeOutCubic,
        child: ValueListenableBuilder<int>(
          valueListenable: _pageCount,
          builder: (context, pageCount, _) => ReaderBottomBar(
          bottomInset: MediaQuery.paddingOf(context).bottom,
          pageLabel: '${_pageIndex + 1}/$pageCount',
          background: paper.background,
          foreground: paper.foreground,
          hasPrevious: session.hasPrevious,
          hasNext: session.hasNext,
          onDirectory: () => _openDirectory(session, settings, controller),
          onPrevious: () {
            _hideToolbar();
            _pendingEntry = null;
            controller.previousChapter();
          },
          onNext: () {
            _hideToolbar();
            _pendingEntry = null;
            controller.nextChapter();
          },
          onSettings: _openSettings,
          ),
        ),
      ),
    );
  }

  void _openSettings() {
    _hideToolbar();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _openDirectory(
    ReaderSessionState session,
    ReaderSettings settings,
    ReaderController controller,
  ) {
    if (session.chapters.isEmpty) return;
    _hideToolbar();
    final paper = settings.paper;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (sheetContext) => ReaderDirectorySheet(
        chapters: session.chapters,
        currentIndex: session.index,
        background: paper.background,
        foreground: paper.foreground,
        onSelected: (index) {
          Navigator.of(sheetContext).pop();
          _pendingEntry = null;
          controller.goToChapter(index);
        },
      ),
    );
  }

  SystemUiOverlayStyle _overlayStyle(ReaderPaper paper) {
    final isNight = paper == ReaderPaper.night;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: isNight ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: isNight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: paper.background,
      systemNavigationBarIconBrightness: isNight
          ? Brightness.light
          : Brightness.dark,
    );
  }
}

/// 分页缓存的 key。正文用对象身份比较：换章/重试拿到新正文对象必然重排。
@immutable
class _PaginationKey {
  const _PaginationKey({
    required this.content,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineHeight,
    required this.textScale,
  });

  final ChapterContent content;
  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;

  /// 用实际缩放后的字号代替 TextScaler 对象，避免不同实例但等价时漏复用。
  final double textScale;

  @override
  bool operator ==(Object other) =>
      other is _PaginationKey &&
      identical(other.content, content) &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.textScale == textScale;

  @override
  int get hashCode => Object.hash(
    identityHashCode(content),
    width,
    height,
    fontSize,
    lineHeight,
    textScale,
  );
}
