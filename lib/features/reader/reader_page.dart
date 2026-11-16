import '../../app/widgets/app_snack_bar.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme/app_theme.dart';
import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/chapter_directory_sheet.dart';
import '../../app/widgets/embedded_detail_sheet.dart';
import '../../app/widgets/inline_error_row.dart';
import '../../app/widgets/states.dart';
import '../../core/storage/reading_store.dart';
import '../../data/models/chapter.dart';
import '../../data/models/chapter_content.dart';
import '../../data/models/chapter_ideas.dart';
import '../../data/models/novel_item.dart';
import '../cache/cache_providers.dart';
import '../cache/offline_task.dart';
import '../cache/widgets/offline_download_button.dart';
import '../detail/detail_page.dart';
import 'reader_actions.dart';
import 'reader_comments.dart';
import 'reader_comments_sheet.dart';
import 'reader_controller.dart';
import 'reader_pagination.dart';
import 'reader_pagination.dart' as reader_pagination;
import 'reader_settings.dart';
import 'reader_widgets.dart';

/// 小说阅读页：分页正文 + 点击分区 + 工具栏 + 设置/目录弹层。
///
/// 分页是"测量一次、缓存起来"的：只有在正文、字号、行距、可读区尺寸或
/// 系统字体缩放变化时才重排，普通重建（工具栏、页码变化）直接复用结果。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.args});

  final ReaderArgs args;

  /// 仅测试用：关掉邻章预排版，让“分页次数/重测段数”这类回归计数只统计
  /// 当前章的显示路径（生产默认开启）。
  @visibleForTesting
  static bool debugDisablePreparation = false;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

/// 换章时落在新章的哪一页：点右侧翻到章尾继续读，应该进下一章第 0 页；
/// 点左侧回上一章，应该落在上一章最后一页，符合"往回翻"的直觉。
enum _ChapterEntry { firstPage, lastPage }

class _ReaderPageState extends ConsumerState<ReaderPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _horizontalPadding = 20;

  /// 底部常驻信息条高度。分页可用高度先扣掉它，所以必须是常量：若让它随
  /// 内容/内边距变化，分页缓存 key 每帧都变，会反复重排。
  static const double _infoBarHeight = 28;

  /// 章边界继续滑动多少逻辑像素触发切章。
  static const double _boundaryOverscrollThreshold = 32;
  static const Duration _pageTurnDuration = Duration(milliseconds: 220);
  static const Duration _toolbarDuration = Duration(milliseconds: 200);

  PageController _pageController = PageController(keepPage: false);
  ReaderPagination? _pagination;
  _PaginationKey? _paginationKey;

  /// 跨 build 的段落测量缓存：段评异步到达、换字号等触发整章重排时，只重测
  /// 真正变化的段落（见 [ReaderBlockMeasureCache]），避免每次整章再测一遍。
  final ReaderBlockMeasureCache _measureCache = ReaderBlockMeasureCache();

  /// 当前章 + 前后各一章的准备结果（正文 / 章评 / 分页）。只保留这三章，
  /// 切到新章后由 [_prunePrepared] 淘汰窗口外的条目。
  final Map<String, _PreparedChapter> _prepared = <String, _PreparedChapter>{};

  /// 章评本地缓存：provider 是 autoDispose，切回同一章会重新请求；这里先
  /// 用缓存渲染，请求回来再替换，避免气泡/章末计数先消失再出现。
  final Map<String, ChapterIdeas> _ideasCache = <String, ChapterIdeas>{};
  final Set<String> _ideasLoading = <String>{};
  final Set<String> _preparing = <String>{};

  /// 当前排版参数（宽高/字号/行距/字重/缩放/气泡开关）。预排版和 sentinel
  /// 只在这个签名一致时复用，否则视为过期。
  _PrepLayout? _activeLayout;

  /// PageView 里“上一章最后一页”sentinel 占掉的一页；没有时为 0。
  int _displayOffset = 0;
  bool _hasPrevSentinel = false;
  bool _hasNextSentinel = false;
  bool _prepScheduled = false;
  int _pageControllerGeneration = 0;

  /// sentinel 落定切章后，新 PageView 第一帧可能还停在夹取后的页；用目标页
  /// 的内容盖住这一帧，等控制器校正完再撤掉，避免“先看到前一页再跳”。
  reader_pagination.ReaderPage? _settlePage;
  String _settlePageChapterId = '';

  /// 从 sentinel 落定切章时不要再播旧的淡入过渡（页面本身已经滑到了目标页）。
  bool _suppressChapterTransition = false;

  int _pageIndex = 0;
  bool _toolbarVisible = false;
  bool _turning = false;
  _ChapterEntry? _pendingEntry;

  /// 换章过渡：正文淡入 + 轻微横向位移。切页（同一章内）仍走 PageView 自己
  /// 的滑动动画，这里只负责"整块正文被换掉"那一下，避免生硬跳变。
  late final AnimationController _chapterTransition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  double _chapterSlide = 0;

  // 章边界继续滑动的手势状态：只对本次手势从首页/末页开始的越界计数。
  int? _dragStartPage;
  double _overscroll = 0;
  bool _edgeTriggered = false;
  bool _boundaryPending = false;

  // 最近一次 build 的快照：dispose 时 provider 可能已在销毁流程里，不能再
  // 通过 ref 读状态，只能靠这些字段把最后一页位置写回进度。
  ReaderSessionState? _lastSession;
  ReaderController? _controller;
  ReadingStore? _readingStore;

  /// 最近一次由"当前页兜底"写进库的落点，用来吸收 inactive → paused 的
  /// 连续触发：位置没变就不再写第二遍。
  String _flushedChapterId = '';
  int _flushedBlockIndex = -1;

  /// 续读落点只恢复一次；后续重排、重进本章都不该再跳。
  bool _resumeApplied = false;

  /// 当前显示章的段评汇总「粘滞」值（见 [_resolveIdeas]）。
  ///
  /// 离线进入时目录会在后台刷新：章的 `version` 从空（离线 manifest 不存）
  /// 换成网络目录里的值，`chapterIdeasProvider` 的 family key 随之变化、重新
  /// 请求。若直接 `?? empty`，已经画出来的气泡会先消失再出现（真机可见的
  /// 闪动），所以同一章在重新请求期间沿用上一份结果。
  ChapterIdeas? _stickyIdeas;
  String _stickyIdeasChapterId = '';

  /// 当前显示章的段评汇总（计数 + variant）。
  ///
  /// 切章/关气泡立即清空；同一章重新请求期间沿用上一份结果，新结果（哪怕是
  /// 空结果）一回来就替换，避免气泡闪一下。
  ChapterIdeas _resolveIdeas(Chapter? chapter, bool showBubbles) {
    if (!showBubbles || chapter == null) {
      _stickyIdeas = null;
      _stickyIdeasChapterId = '';
      return ChapterIdeas.empty;
    }
    if (chapter.id != _stickyIdeasChapterId) {
      _stickyIdeas = null;
      _stickyIdeasChapterId = chapter.id;
    }
    final value = ref
        .watch(
          chapterIdeasProvider(
            ChapterCommentsArgs(
              bookId: widget.args.bookId,
              chapterId: chapter.id,
              itemVersion: chapter.version,
            ),
          ),
        )
        .value;
    if (value != null) {
      _stickyIdeas = value;
      _ideasCache[chapter.id] = value;
    }
    return value ??
        _ideasCache[chapter.id] ??
        _stickyIdeas ??
        ChapterIdeas.empty;
  }

  @override
  void initState() {
    super.initState();
    // 切后台时把当前页立即落盘：5s 防抖窗口内被系统挂起/杀掉就丢掉这几页。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushReadingPosition();
    _pageController.dispose();
    // 切章过渡在快速进出/真机打断时会停在半路，ticker 不释放会被框架断言。
    _chapterTransition.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive 早于 paused：iOS 上能在进程被挂起前抢到更多时间，也保证这次
    // 写入早于 SyncLifecycle 在 paused 触发的同步，上传的是最新进度。
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    _flushReadingPosition();
  }

  /// 立即把当前页落盘（退出阅读页、App 切后台时调用，防抖可能还没到点）。
  ///
  /// 落完盘顺手丢掉控制器里的防抖进度：那份只会更旧，留着会在下次切章时把
  /// 旧落点覆盖回去。中途 return 时不动它，交给防抖自己落盘。
  void _flushReadingPosition() {
    final session = _lastSession;
    final pagination = _pagination;
    final store = _readingStore;
    if (session == null || pagination == null || store == null) return;
    if (pagination.pages.isEmpty) return;
    // 切章在途时显示的还是上一章正文、控制器已保存目标章：不要用旧页覆盖。
    if (session.index != session.contentIndex) return;
    final chapter = session.chapterAt(session.contentIndex);
    if (chapter == null) return;
    final pageIndex = _pageIndex.clamp(0, pagination.pages.length - 1).toInt();
    final blockIndex = pagination.blockAtPage(pageIndex);
    // 纯字段操作，provider 已在销毁流程里也能安全调用。
    _controller?.discardPendingProgress();
    // inactive → paused 会连着触发两次；位置没变就不再写第二遍。
    if (chapter.id == _flushedChapterId && blockIndex == _flushedBlockIndex) {
      return;
    }
    _flushedChapterId = chapter.id;
    _flushedBlockIndex = blockIndex;
    unawaited(
      store.saveProgress(
        bookId: widget.args.bookId,
        bookTitle: session.bookTitle,
        cover: session.cover,
        chapterId: chapter.id,
        chapterIndex: chapter.index,
        blockIndex: blockIndex,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = readerSessionProvider(widget.args);
    final session = ref.watch(provider);
    final settings = ref.watch(readerSettingsProvider);
    final fontWeight = ref.watch(readerEffectiveFontWeightProvider);
    final controller = ref.read(provider.notifier);
    // 段评是当前「正在显示」那一章的；切章加载期间正文仍是上一章，用
    // contentIndex 而不是 index，避免把下一章的计数画到上一章上。
    final displayedChapter = session.chapterAt(session.contentIndex);
    // 段评气泡关闭时不预取计数：工具栏「评论」入口按需再取（见
    // _openChapterComments）。这样关掉气泡后每章 0 请求。
    final ideas = _resolveIdeas(displayedChapter, settings.showBubbles);
    _lastSession = session;
    _controller = controller;
    // ReadingStore 是进程级 Provider，页面 dispose 后实例仍然有效。
    _readingStore ??= ref.read(readingStoreProvider);
    final paper = settings.paper;

    // 正文真正换了（contentIndex 变化）才播过渡：向前翻从右侧滑入、向后翻
    // 从左侧滑入。加载态切换不播，避免"先淡入 loading 再淡入正文"两次闪。
    ref.listen<ReaderSessionState>(provider, (previous, next) {
      if (previous == null || next.contentIndex < 0) return;
      if (previous.contentIndex == next.contentIndex) return;
      // 从 sentinel 页落定切章：页面已经滑到目标页，不能再叠加淡入。
      if (_suppressChapterTransition) {
        _suppressChapterTransition = false;
        return;
      }
      _chapterSlide = next.contentIndex >= previous.contentIndex ? 1 : -1;
      _chapterTransition.forward(from: 0);
    });

    // 气泡从「关」切回「开」：当前正文若是老缓存（没有段落锚点），立刻补取
    // 一次，否则要等重进本章才看得到气泡。
    ref.listen<ReaderSettings>(readerSettingsProvider, (previous, next) {
      if (previous == null || previous.showBubbles == next.showBubbles) return;
      if (next.showBubbles) controller.ensureAnchorUpgrade();
    });

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
                  // 正文里的段评气泡按纸色取色（夜间纸色要用深色 scheme 才看得清），
                  // 其余控件都显式传色，包一层主题只影响气泡与空/错态视图。
                  child: Theme(
                    data: _readerTheme(settings.paper),
                    child: _buildBody(
                      session,
                      settings,
                      controller,
                      ideas,
                      fontWeight,
                    ),
                  ),
                ),
              ),
            ),
            // 工具栏打开时压暗正文，让浮层上的文字更清楚；本身不接收点击，
            // 点击穿透到正文的手势识别器，交给 _handleTap 收起工具栏。
            // （工具栏打开时横向翻页已由 PageView 的 physics 锁住，见
            // _buildPagedContent；遮罩只负责视觉压暗，不抢手势。）
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
              child: _buildBottomBar(settings),
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
    ChapterIdeas ideas,
    FontWeight fontWeight,
  ) {
    final paper = settings.paper;
    final error = session.error;
    // 首次进入还没有正文时，失败只能整页报错；已经读到正文时保留正文，
    // 错误降级成正文顶部的提示条（见 _buildPagedContent），别因为一次网络
    // 抖动把正在读的章清掉。
    if (error != null && session.content == null) {
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
    return _buildPagedContent(
      session,
      settings,
      content,
      controller,
      ideas,
      fontWeight,
    );
  }

  /// 共享状态视图在夜间底色下要换一套亮色 scheme，否则文字会看不清。
  Widget _buildStatus(ReaderPaper paper, Widget child) {
    return ColoredBox(
      color: paper.background,
      child: Theme(data: _readerTheme(paper), child: child),
    );
  }

  /// 阅读纸色对应的一套主题：配色方案按纸色的明暗重新派生。
  ///
  /// 弹层（设置/目录）也要用它包一层——底部弹层挂在 root
  /// Navigator 上，不包就会拿到全局主题的 primary，在纸色/夜间底色上对比度
  /// 不够（暗色 App + 纸色底时曾经低到 1.5:1）。
  ThemeData _readerTheme(ReaderPaper paper) {
    final brightness = paper == ReaderPaper.night
        ? Brightness.dark
        : Brightness.light;
    return Theme.of(context).copyWith(
      colorScheme: AppTheme.schemeFor(
        // 跟着「设置 → 主题色」走：阅读页的工具栏/目录高亮也要一起换色。
        AppTheme.accentOf(context),
        brightness,
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
    ReaderController controller,
    ChapterIdeas ideas,
    FontWeight fontWeight,
  ) {
    final paper = settings.paper;
    final foreground = paper.foreground;
    // 在 build 阶段取一次主题字体，避免在 LayoutBuilder 的布局阶段做
    // InheritedWidget 查找；测量与渲染用同一个值。
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final textStyle = _readerTextStyle(
      settings,
      foreground,
      fontFamily,
      fontWeight,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final infoStyle = TextStyle(
      fontSize: 11.5,
      height: 1.2,
      color: foreground.withValues(alpha: 0.5),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - _horizontalPadding * 2;
        // 常驻信息条占固定高度，先扣掉再分页；布局与分页用同一个常量，
        // 不会出现“信息条一刷新正文就重排”的抖动。
        final pageHeight = constraints.maxHeight - _infoBarHeight;
        final layout = _PrepLayout(
          width: contentWidth,
          height: pageHeight,
          fontSize: settings.fontSize,
          lineHeight: settings.lineHeight,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          textScaler: textScaler,
          showBubbles: settings.showBubbles,
          showDialogueHighlight: settings.showDialogueHighlight,
        );
        _activeLayout = layout;
        final prevPrepared = _preparedFor(
          session,
          session.contentIndex - 1,
          layout,
        );
        final nextPrepared = _preparedFor(
          session,
          session.contentIndex + 1,
          layout,
        );
        final displayOffset = prevPrepared == null ? 0 : 1;
        final offsetBefore = _displayOffset;
        final controllerBefore = _pageController;
        final pagination = contentWidth <= 0 || pageHeight <= 0
            ? null
            : _obtainPagination(
                content: content,
                layout: layout,
                ideas: ideas,
                displayOffset: displayOffset,
              );
        if (pagination == null || pagination.pages.isEmpty) {
          return _buildStatus(
            paper,
            const EmptyView(message: '本章暂无正文', icon: Icons.article_outlined),
          );
        }
        final pages = pagination.pages;
        // 当前章也记进准备缓存：切到下一章后它要当“上一章 last page” sentinel。
        _prepared[content.id] = _PreparedChapter(
          chapterId: content.id,
          content: content,
          ideas: ideas,
          pagination: pagination,
          layout: layout,
        );
        _hasPrevSentinel = prevPrepared != null;
        _hasNextSentinel = nextPrepared != null;
        // prev sentinel 是在当前页前面插了一页，PageView 的索引整体 +1；
        // 预排版刚完成时用新 PageController 直接以正确页码重建，避免先显示
        // 错位一页再 jump 过去。
        if (offsetBefore != displayOffset &&
            identical(controllerBefore, _pageController)) {
          _restartPageController(displayOffset + _pageIndex);
        }
        _schedulePreparation(session, layout);
        // 续读入口：首次分页完成后按 blockIndex 落到对应页（只做一次）。
        _applyResumeIfNeeded(session, pagination);
        final pageIndex = _pageIndex.clamp(0, pages.length - 1).toInt();
        final displayPageCount =
            displayOffset + pages.length + (_hasNextSentinel ? 1 : 0);
        return AnimatedBuilder(
          animation: _chapterTransition,
          child: Column(
            children: [
              SizedBox(
                height: pageHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: PageView.builder(
                          // 换 PageController 时必须同时换 PageView 的 key：
                          // 同一个 element 里换 controller 会沿用旧 ScrollPosition，
                          // initialPage 不生效，导致回到上一章时页码/内容错位或
                          // 先画错页再校正。generation 保证每次 restart 都是新元素。
                          key: ValueKey<String>(
                            'reader-pager-${pagination.chapterId}-'
                            '$_pageControllerGeneration',
                          ),
                          controller: _pageController,
                          // 不用 iOS 回弹物理：回弹不产生 OverscrollNotification，
                          // 章边界继续滑动就检测不到。Clamping 既保留 PageView
                          // 的贴页回弹吸附，又能拿到越界量。
                          // 工具栏打开时锁死横向滑动：这个状态下手势用来收工具栏/
                          // 点按钮，再翻页会误触（setState 切换后立即重建生效）。
                          physics: _toolbarVisible
                              ? const NeverScrollableScrollPhysics()
                              : const ClampingScrollPhysics(),
                          itemCount: displayPageCount,
                          onPageChanged: _onPageChanged,
                          itemBuilder: (context, index) {
                            final bool isPrevSentinel =
                                _hasPrevSentinel && index == 0;
                            final bool isNextSentinel =
                                _hasNextSentinel &&
                                index == displayOffset + pages.length;
                            final bool inCurrent =
                                !isPrevSentinel && !isNextSentinel;
                            final reader_pagination.ReaderPage page;
                            if (isPrevSentinel) {
                              page = prevPrepared!.pagination.pages.last;
                            } else if (isNextSentinel) {
                              page = nextPrepared!.pagination.pages.first;
                            } else {
                              page = pages[index - displayOffset];
                            }
                            return RepaintBoundary(
                              child: ReaderPageContent(
                                page: page,
                                textStyle: textStyle,
                                textScaler: textScaler,
                                contentWidth: contentWidth,
                                horizontalPadding: _horizontalPadding,
                                showDialogueHighlight:
                                    settings.showDialogueHighlight,
                                dialogueHighlightColor:
                                    settings.dialogueHighlightColor,
                                dialogueHighlightStyle:
                                    settings.dialogueHighlightStyle,
                                // sentinel 页不属于当前章，气泡不接点击。
                                onBubbleTap: inCurrent
                                    ? _openParagraphComments
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (_settlePage != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: paper.background,
                            child: ReaderPageContent(
                              // 新正文已经到达就用新分页的目标页；还在加载旧章
                              // 时用 sentinel 的目标页（两者内容一致）。
                              page: content.id == _settlePageChapterId
                                  ? pages[_pageIndex.clamp(0, pages.length - 1)]
                                  : _settlePage!,
                              textStyle: textStyle,
                              textScaler: textScaler,
                              contentWidth: contentWidth,
                              horizontalPadding: _horizontalPadding,
                              showDialogueHighlight:
                                  settings.showDialogueHighlight,
                              dialogueHighlightColor:
                                  settings.dialogueHighlightColor,
                              dialogueHighlightStyle:
                                  settings.dialogueHighlightStyle,
                              onBubbleTap: null,
                            ),
                          ),
                        ),
                      ),
                    if (session.loading && _settlePage == null)
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
                    // 切章失败：正文仍然是上一章（controller 已把 index 退回
                    // contentIndex），错误只以提示条形式出现，读完这页再决定
                    // 重试还是继续读别的章。
                    if (session.error != null)
                      Positioned(
                        top: 8,
                        left: 12,
                        right: 12,
                        child: _buildLoadErrorBanner(
                          session,
                          controller,
                          foreground,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: _infoBarHeight,
                child: _buildInfoBar(
                  session,
                  pageIndex,
                  pages.length,
                  infoStyle,
                ),
              ),
            ],
          ),
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(
              _chapterTransition.value.clamp(0.0, 1.0),
            );
            return Opacity(
              opacity: 0.65 + 0.35 * t,
              child: FractionalTranslation(
                translation: Offset((1 - t) * 0.06 * _chapterSlide, 0),
                child: child,
              ),
            );
          },
        );
      },
    );
  }

  /// 按 [ReaderSessionState.resumeBlockIndex] 恢复页级进度。
  ///
  /// 只对"按本地进度续读"的入口章生效一次：换字号重排、返回本章都走
  /// 已有的首段锚点逻辑，不能再跳回旧的恢复点。
  void _applyResumeIfNeeded(
    ReaderSessionState session,
    ReaderPagination pagination,
  ) {
    if (_resumeApplied) return;
    final resumeChapter = session.resumeChapterIndex;
    if (resumeChapter < 0 || session.contentIndex != resumeChapter) return;
    _resumeApplied = true;
    final blockIndex = session.resumeBlockIndex;
    if (blockIndex > 0 && pagination.pages.isNotEmpty) {
      // pageIndexForBlock 会把越界 blockIndex 夹到最后一页，不会因为目录/正文
      // 变短而落到无效页。
      final target = pagination.pageIndexForBlock(blockIndex);
      if (target != _pageIndex) {
        _pageIndex = target;
        // 首次分页时直接用目标页做 PageController 初始页，避免先画第 0 页。
        _restartPageController(target + _displayOffset);
      }
    }
    final provider = readerSessionProvider(widget.args);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(provider.notifier).clearResumeBlock();
      // 越界的 blockIndex 会被夹到最后一页，顺手把归一化后的落点写回去。
      _rememberPosition();
    });
  }

  /// 把当前页首段下标报给控制器（防抖后落盘，见 ReaderController.progressDebounce）。
  void _rememberPosition() {
    final pagination = _pagination;
    if (pagination == null || pagination.pages.isEmpty) return;
    final pageIndex = _pageIndex.clamp(0, pagination.pages.length - 1).toInt();
    _controller?.noteReadingBlock(pagination.blockAtPage(pageIndex));
  }

  /// 常驻信息条：左侧章节名最多半屏宽，右侧当前页/本章总页数。
  /// 它不属于工具栏，收起工具栏时也一直在，方便随时知道读到哪。
  Widget _buildInfoBar(
    ReaderSessionState session,
    int pageIndex,
    int pageCount,
    TextStyle style,
  ) {
    final chapterTitle = session.displayedChapter?.title ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.5,
                ),
                child: Text(
                  chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ),
          ),
          Text('${pageIndex + 1}/$pageCount', style: style),
        ],
      ),
    );
  }

  /// 切章失败的顶部提示条：不挡正文，给「重试 / 关闭」两个动作。
  ///
  /// 失败目标可能是用户正在翻去的下一章，而正文还停在上一章，所以文案里
  /// 必须带上失败的是第几章，否则用户不知道点重试会去哪。
  Widget _buildLoadErrorBanner(
    ReaderSessionState session,
    ReaderController controller,
    Color foreground,
  ) {
    final failedIndex = session.failedIndex >= 0
        ? session.failedIndex
        : session.index;
    final chapter = session.chapterAt(failedIndex);
    final title = chapter == null ? '正文加载失败' : '「${chapter.title}」加载失败';
    return InlineErrorRow(
      message: '$title：${session.error ?? ''}',
      foreground: foreground,
      background: foreground.withValues(alpha: 0.07),
      padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
      onRetry: () => unawaited(controller.retry()),
      onDismiss: controller.dismissError,
    );
  }

  /// PageView 滚动通知：只有「从首页继续往右滑」「从末页继续往左滑」
  /// 才累计越界量并切章；手势途中先翻到边界的不算，避免一次手势连跳两章。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragStartPage = _pageIndex;
      _overscroll = 0;
      _edgeTriggered = false;
      return false;
    }
    if (notification is ScrollEndNotification) {
      _dragStartPage = null;
      final pagination = _pagination;
      if (pagination != null && _pageController.hasClients) {
        final display = _pageController.page?.round();
        if (display != null) {
          final local = display - _displayOffset;
          if (local < 0) {
            unawaited(_commitSentinel(-1));
          } else if (local >= pagination.pages.length) {
            unawaited(_commitSentinel(1));
          }
        }
      }
      return false;
    }
    if (notification is! OverscrollNotification ||
        notification.dragDetails == null ||
        _edgeTriggered ||
        _boundaryPending) {
      return false;
    }
    final pagination = _pagination;
    final startPage = _dragStartPage;
    if (pagination == null || pagination.pages.isEmpty || startPage == null) {
      return false;
    }
    // 向右越界（负 overscroll）= 想回上一章；向左越界 = 想进下一章。
    final direction = notification.overscroll < 0 ? -1 : 1;
    // 该方向已经有 sentinel 页：边界由 PageView 的原生滑动负责，这里不能再
    // 触发旧的“越界直接切章”，否则会在 sentinel 上再切一次。
    if (direction < 0 && _hasPrevSentinel) return false;
    if (direction > 0 && _hasNextSentinel) return false;
    final expectedStart = direction < 0 ? 0 : pagination.pages.length - 1;
    if (startPage != expectedStart) return false;
    _overscroll += notification.overscroll;
    if (_overscroll.abs() > _boundaryOverscrollThreshold) {
      _edgeTriggered = true;
      unawaited(_crossChapter(direction));
    }
    return false;
  }

  /// 滑到 sentinel 页并落定后，原子切到目标章。
  ///
  /// 此时 PageView 已经像普通翻页一样滑到了目标页；切章后新 PageView 的
  /// 初始页指向同一页内容，所以不需要淡入过渡（[_suppressChapterTransition]）。
  /// 如果正文没取到（断网且无缓存），把 PageView 退回当前章原来的页，避免
  /// 停在一个假的 sentinel 上。
  Future<void> _commitSentinel(int direction) async {
    if (_boundaryPending) return;
    final session = ref.read(readerSessionProvider(widget.args));
    if (session.loading || session.index != session.contentIndex) return;
    if (direction < 0 && !session.hasPrevious) return;
    if (direction > 0 && !session.hasNext) return;
    _boundaryPending = true;
    _suppressChapterTransition = true;
    _rememberPosition();
    _pendingEntry = direction < 0
        ? _ChapterEntry.lastPage
        : _ChapterEntry.firstPage;
    // 目标页的内容先盖住新 PageView 的第一帧：从 sentinel 返回时，控制器
    // 可能被旧 itemCount 夹到前一页，校正发生在 post-frame；这一层让用户
    // 看不到中间的错页。
    final targetPosition = session.contentIndex + direction;
    if (targetPosition >= 0 && targetPosition < session.chapters.length) {
      final targetChapter = session.chapters[targetPosition];
      final prepared = _prepared[targetChapter.id];
      if (prepared != null && prepared.pagination.pages.isNotEmpty) {
        final targetPage = direction < 0
            ? prepared.pagination.pages.last
            : prepared.pagination.pages.first;
        setState(() {
          _settlePage = targetPage;
          _settlePageChapterId = targetChapter.id;
        });
      }
    }
    final controller = ref.read(readerSessionProvider(widget.args).notifier);
    try {
      if (direction < 0) {
        await controller.previousChapter();
      } else {
        await controller.nextChapter();
      }
    } finally {
      _boundaryPending = false;
      _suppressChapterTransition = false;
      if (mounted) {
        final now = ref.read(readerSessionProvider(widget.args));
        if (now.contentIndex == session.contentIndex) {
          // 切章失败：正文仍停在原章，退回原页。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_pageController.hasClients) return;
            _pageController.jumpToPage(_displayOffset + _pageIndex);
          });
          if (_settlePage != null) setState(() => _settlePage = null);
        }
      }
    }
  }

  /// 章边界继续滑动的切章入口。落点与点击分区一致：回上一章落最后一页，
  /// 进下一章落第一页；并清掉旧落点、收起工具栏，避免连跳两章。
  Future<void> _crossChapter(int direction) async {
    if (_boundaryPending || _turning) return;
    final session = ref.read(readerSessionProvider(widget.args));
    if (session.loading || session.index != session.contentIndex) return;
    if (direction < 0 && !session.hasPrevious) return;
    if (direction > 0 && !session.hasNext) return;
    // 边界切章前先把当前页的段落下标记下来，由控制器立即落盘。
    _rememberPosition();
    final controller = ref.read(readerSessionProvider(widget.args).notifier);
    _pendingEntry = direction < 0
        ? _ChapterEntry.lastPage
        : _ChapterEntry.firstPage;
    _hideToolbar();
    _boundaryPending = true;
    try {
      if (direction < 0) {
        await controller.previousChapter();
      } else {
        await controller.nextChapter();
      }
    } finally {
      if (mounted) _boundaryPending = false;
    }
  }

  /// 正文样式：`inherit: false` 是关键——Text 默认会和 DefaultTextStyle 合并
  /// （例如 leadingDistribution），而 TextPainter 不合并，两者行高会不一致。
  /// 这里用固定样式同时喂给测量与渲染，保证断行绝对一致。
  ///
  /// 字体跟随主题：App 若换了正文字体，分页测量也必须是同一套字形度量。
  TextStyle _readerTextStyle(
    ReaderSettings settings,
    Color color,
    String? fontFamily,
    FontWeight fontWeight,
  ) {
    return AppTheme.readerText(
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      color: color,
      fontWeight: fontWeight,
    ).copyWith(inherit: false, fontFamily: fontFamily);
  }

  /// 拿分页结果；输入没变就直接返回缓存，绝不每帧重排。
  ///
  /// [displayOffset] 是 PageView 前面多出来的「上一章最后一页」sentinel 数
  /// （0/1）。
  ReaderPagination _obtainPagination({
    required ChapterContent content,
    required _PrepLayout layout,
    required ChapterIdeas ideas,
    required int displayOffset,
  }) {
    final key = _paginationKeyFor(content, layout, ideas);
    final cached = _pagination;
    if (cached != null && _paginationKey == key) {
      _displayOffset = displayOffset;
      return cached;
    }

    final sameChapter = cached != null && cached.chapterId == content.id;
    // 重排前记下当前页首段，重排后回到包含它的那一页。
    final anchorBlock = sameChapter && cached.pages.isNotEmpty
        ? cached.blockAtPage(_pageIndex)
        : null;
    // 相邻章可能已经预排版过；key/正文完全一致时直接复用，省掉一次整章测量。
    final prepared = _prepared[content.id];
    final pagination =
        prepared != null &&
            prepared.layout == layout &&
            identical(prepared.content, content) &&
            identical(prepared.ideas, ideas)
        ? prepared.pagination
        : _buildPaginationFor(content, ideas, layout);
    _pagination = pagination;
    _paginationKey = key;

    if (cached == null) {
      _pageIndex = 0;
      _displayOffset = displayOffset;
      if (displayOffset != 0) _restartPageController(displayOffset);
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
      _displayOffset = displayOffset;
      _restartPageController(target + displayOffset);
      // 上一章落最后一页时 PageView 直接以该页为初始页，不会触发
      // onPageChanged，这里补记一次，退出/切章时进度才是这一页。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _rememberPosition();
      });
    } else {
      final anchor = anchorBlock;
      final target = anchor == null ? 0 : pagination.pageIndexForBlock(anchor);
      _pageIndex = target;
      _scheduleJump(target);
    }
    return pagination;
  }

  /// 取排版签名一致的邻章准备结果；正文/页为空或排版过期都当没有。
  _PreparedChapter? _preparedFor(
    ReaderSessionState session,
    int position,
    _PrepLayout layout,
  ) {
    if (position < 0 || position >= session.chapters.length) return null;
    final chapter = session.chapters[position];
    final prepared = _prepared[chapter.id];
    if (prepared == null ||
        prepared.layout != layout ||
        prepared.pagination.pages.isEmpty) {
      return null;
    }
    return prepared;
  }

  /// 当前章稳定后，在后台把前后章（正文 + 章评 + 分页）准备好。
  ///
  /// 每帧 build 都会调用；如果窗口内都已就绪就直接 return，不产生额外
  /// 异步任务。预排版放在 post-frame，避免抢当前章首帧。
  void _schedulePreparation(ReaderSessionState session, _PrepLayout layout) {
    if (ReaderPage.debugDisablePreparation) return;
    if (_prepScheduled || !_needsPreparation(session, layout)) return;
    _prepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _prepScheduled = false;
      if (!mounted) return;
      final current = ref.read(readerSessionProvider(widget.args));
      if (!mounted || _activeLayout != layout || current.content == null) {
        return;
      }
      var changed = await _prepareNeighbor(
        current,
        current.contentIndex + 1,
        layout,
      );
      if (!mounted || _activeLayout != layout) return;
      changed =
          await _prepareNeighbor(current, current.contentIndex - 1, layout) ||
          changed;
      if (!mounted) return;
      changed = _prunePrepared(current) || changed;
      if (changed && mounted) setState(() {});
    });
  }

  bool _needsPreparation(ReaderSessionState session, _PrepLayout layout) {
    for (final position in [
      session.contentIndex - 1,
      session.contentIndex + 1,
    ]) {
      if (position < 0 || position >= session.chapters.length) continue;
      final chapter = session.chapters[position];
      if (_prepared[chapter.id]?.layout != layout) return true;
    }
    return false;
  }

  Future<bool> _prepareNeighbor(
    ReaderSessionState session,
    int position,
    _PrepLayout layout,
  ) async {
    if (position < 0 || position >= session.chapters.length) return false;
    final chapter = session.chapters[position];
    if (_preparing.contains(chapter.id) ||
        _prepared[chapter.id]?.layout == layout) {
      return false;
    }
    _preparing.add(chapter.id);
    try {
      final content = await ref
          .read(readerSessionProvider(widget.args).notifier)
          .prepareChapterContent(position);
      if (!mounted || content == null || _activeLayout != layout) return false;
      final ideas = await _loadIdeasFor(chapter, layout.showBubbles);
      if (!mounted || _activeLayout != layout) return false;
      final pagination = _buildPaginationFor(content, ideas, layout);
      if (!mounted || _activeLayout != layout) return false;
      _prepared[chapter.id] = _PreparedChapter(
        chapterId: chapter.id,
        content: content,
        ideas: ideas,
        pagination: pagination,
        layout: layout,
      );
      return true;
    } finally {
      _preparing.remove(chapter.id);
    }
  }

  /// 章评也提前拉：provider 是 autoDispose，切回旧章会重新请求；本地缓存
  /// 先保证首屏渲染，请求回来再按 provider 的新值刷新。
  Future<ChapterIdeas> _loadIdeasFor(Chapter chapter, bool showBubbles) async {
    if (!showBubbles) return ChapterIdeas.empty;
    final cached = _ideasCache[chapter.id];
    if (cached != null) return cached;
    if (!_ideasLoading.add(chapter.id)) return ChapterIdeas.empty;
    try {
      final ideas = await ref.read(
        chapterIdeasProvider(
          ChapterCommentsArgs(
            bookId: widget.args.bookId,
            chapterId: chapter.id,
            itemVersion: chapter.version,
          ),
        ).future,
      );
      if (!mounted) return ideas;
      _ideasCache[chapter.id] = ideas;
      return ideas;
    } catch (_) {
      return ChapterIdeas.empty;
    } finally {
      _ideasLoading.remove(chapter.id);
    }
  }

  /// 只保留当前章和前后各一章；其余（更早读过的）准备结果及时释放。
  bool _prunePrepared(ReaderSessionState session) {
    final keep = <String>{};
    for (final position in [
      session.contentIndex - 1,
      session.contentIndex,
      session.contentIndex + 1,
    ]) {
      if (position < 0 || position >= session.chapters.length) continue;
      keep.add(session.chapters[position].id);
    }
    final before = _prepared.length + _ideasCache.length;
    _prepared.removeWhere((id, _) => !keep.contains(id));
    _ideasCache.removeWhere((id, _) => !keep.contains(id));
    return _prepared.length + _ideasCache.length != before;
  }

  _PaginationKey _paginationKeyFor(
    ChapterContent content,
    _PrepLayout layout,
    ChapterIdeas ideas,
  ) => _PaginationKey(
    content: content,
    width: layout.width,
    height: layout.height,
    fontSize: layout.fontSize,
    lineHeight: layout.lineHeight,
    fontWeight: layout.fontWeight,
    textScale: layout.textScaler.scale(16),
    fontFamily: layout.fontFamily,
    ideas: ideas,
    showBubbles: layout.showBubbles,
    showDialogueHighlight: layout.showDialogueHighlight,
  );

  ReaderPagination _buildPaginationFor(
    ChapterContent content,
    ChapterIdeas ideas,
    _PrepLayout layout,
  ) {
    return ReaderPagination.build(
      chapterId: content.id,
      paragraphs: content.paragraphs,
      paraIndices: content.paraIndices,
      showBubbles: layout.showBubbles,
      bubbleCounts: ideas.bubbleCounts,
      bubbleVariants: ideas.bubbleVariants,
      spec: ReaderLayoutSpec(
        width: layout.width,
        height: layout.height,
        textScaler: layout.textScaler,
        bodyStyle: AppTheme.readerText(
          fontSize: layout.fontSize,
          lineHeight: layout.lineHeight,
          color: Colors.black,
          fontWeight: layout.fontWeight,
        ).copyWith(inherit: false, fontFamily: layout.fontFamily),
        paragraphSpacing: layout.fontSize * 0.55,
      ),
      showDialogueHighlight: layout.showDialogueHighlight,
      measureCache: _measureCache,
    );
  }

  /// 换掉 PageController 后旧的滚动位置就作废了；等这一帧把旧 PageView
  /// 卸载（detach 掉 position）之后再释放旧控制器。
  void _restartPageController(int initialPage) {
    final retired = _pageController;
    final generation = ++_pageControllerGeneration;
    _pageController = PageController(initialPage: initialPage, keepPage: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      retired.dispose();
      _stabilizeController(initialPage, generation);
    });
  }

  /// PageView 重建前如果旧页数更少，initialPage 可能被旧的 itemCount 夹取
  /// （从第 2 章回第 1 章时表现为「信息条 10/10、内容却是第 9 页」）。
  /// 新页数布局完成后校正，并连续确认几帧再撤 sentinel 覆盖层：不同设备上
  /// ScrollPosition 的 clamp 可能晚一帧发生，只校正一次仍会闪。
  void _stabilizeController(int expected, int generation) {
    var attempts = 0;
    void check() {
      if (!mounted || generation != _pageControllerGeneration) return;
      if (_pageController.hasClients) {
        if (_pageController.page?.round() != expected) {
          _pageController.jumpToPage(expected);
        }
      }
      attempts++;
      if (attempts >= 3) {
        if (_settlePage != null && mounted) {
          setState(() => _settlePage = null);
        }
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => check());
    }

    check();
  }

  void _scheduleJump(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      // 排队的跳页可能已经过时（用户自己滑走了），以最新页码为准。
      if (_pageIndex != page) return;
      final displayPage = page + _displayOffset;
      if (_pageController.page?.round() == displayPage) return;
      _pageController.jumpToPage(displayPage);
    });
  }

  void _onPageChanged(int index) {
    if (!mounted) return;
    final pagination = _pagination;
    if (pagination == null) return;
    final local = index - _displayOffset;
    // sentinel（上一章最后一页 / 下一章第一页）不算当前章的页码；
    // 等滚动落定后由 _commitSentinel 原子切章。
    if (local < 0 || local >= pagination.pages.length) return;
    if (local != _pageIndex) {
      setState(() => _pageIndex = local);
    }
    _rememberPosition();
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
      if (_hasPrevSentinel) {
        // 上一章最后一页已经在 PageView 里：用和普通翻页一样的动画滑过去，
        // 落定后由 _onScrollNotification 原子切章。
        _turning = true;
        try {
          await _pageController.animateToPage(
            0,
            duration: _pageTurnDuration,
            curve: Curves.easeOutCubic,
          );
        } finally {
          _turning = false;
        }
        return;
      }
      _rememberPosition();
      _pendingEntry = _ChapterEntry.lastPage;
      await controller.previousChapter();
      return;
    }
    if (target >= pagination.pages.length) {
      if (!session.hasNext) return;
      if (_hasNextSentinel) {
        // 下一章第一页已在 PageView 末尾，和章内翻页同一条动画。
        _turning = true;
        try {
          await _pageController.animateToPage(
            _displayOffset + pagination.pages.length,
            duration: _pageTurnDuration,
            curve: Curves.easeOutCubic,
          );
        } finally {
          _turning = false;
        }
        return;
      }
      _rememberPosition();
      _pendingEntry = _ChapterEntry.firstPage;
      await controller.nextChapter();
      return;
    }
    _turning = true;
    try {
      await _pageController.animateToPage(
        target + _displayOffset,
        duration: _pageTurnDuration,
        curve: Curves.easeOutCubic,
      );
    } finally {
      _turning = false;
    }
    // 动画结束再确认一次当前页（onPageChanged 也可能没触发）。
    _rememberPosition();
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
    final bookId = widget.args.bookId;
    // 加入书架只加不移：书架状态以存储为准，加入成功后再 invalidate 重读。
    final onShelf = ref.watch(readerShelfProvider(bookId)).value ?? false;
    final cacheStatus = ref.watch(
      offlineEntryStatusProvider((kind: OfflineTaskKind.novel, id: bookId)),
    );
    final cacheLabel = switch (cacheStatus) {
      OfflineEntryStatus.none => '缓存小说',
      OfflineEntryStatus.inProgress => '缓存中',
      OfflineEntryStatus.cached => '已缓存',
    };
    // 未缓存：就地开始整本下载；下载中/暂停/半截/排队/已缓存：去缓存中心
    // 看进度、继续/重试或删除。阅读页里除「已在书架」外都能点，不能让
    // 「缓存中」「已缓存」变成点不动的死状态。
    final VoidCallback onCacheTap = switch (cacheStatus) {
      OfflineEntryStatus.none => () => unawaited(_startCaching(session)),
      OfflineEntryStatus.inProgress || OfflineEntryStatus.cached =>
        () => unawaited(context.pushAppRoute(const CacheCenterRoute())),
    };
    return IgnorePointer(
      ignoring: !_toolbarVisible,
      child: AnimatedSlide(
        offset: _toolbarVisible ? Offset.zero : const Offset(0, -1.02),
        duration: _toolbarDuration,
        curve: Curves.easeOutCubic,
        child: ReaderTopBar(
          topInset: MediaQuery.paddingOf(context).top,
          background: paper.background,
          foreground: paper.foreground,
          onBack: _onBack,
          // 会话里书名来自入参/详情/离线 manifest，兜底再用路由参数。
          title: session.bookTitle.isNotEmpty
              ? session.bookTitle
              : widget.args.bookTitle,
          shelfLabel: onShelf ? '已在书架' : '加入书架',
          onShelfTap: onShelf ? null : () => unawaited(_addToShelf(session)),
          cacheLabel: cacheLabel,
          onCacheTap: onCacheTap,
        ),
      ),
    );
  }

  /// 顶部「加入书架」：只加不移除。
  ///
  /// 已经在书架时按钮不再是按钮（[ReaderTopBar.onShelfTap] 传 null），所以
  /// 这里没有 remove 分支：阅读页里书架状态只读，移出统一回详情页做。
  ///
  /// 会话里只有书名/封面，没有作者与分类，所以书架条目比详情页加入的精简
  /// （书架卡副标题会少一行）；为补全这两个字段在阅读页多发一次详情请求
  /// 不值得，书架里点进去就能看到完整详情。
  Future<void> _addToShelf(ReaderSessionState session) async {
    final item = NovelItem(
      id: widget.args.bookId,
      title: session.bookTitle.isNotEmpty
          ? session.bookTitle
          : widget.args.bookTitle,
      cover: session.cover.isNotEmpty ? session.cover : widget.args.cover,
    );
    if (!item.isValid) {
      _showMessage('书名还没加载好，请稍后再试');
      return;
    }
    try {
      await ref.read(readingStoreProvider).addToShelf(item);
    } catch (_) {
      _showMessage('加入书架失败，请重试');
      return;
    }
    // 落盘成功才刷新按钮文案；失败时保持「加入书架」让用户重试。
    // await 之后页面可能已经被返回键关掉，此时 invalidate 会访问已卸载的
    // ConsumerState 而抛 StateError（调用方是 unawaited，会变成未捕获异常）。
    if (!mounted) return;
    ref.invalidate(readerShelfProvider(widget.args.bookId));
  }

  /// 顶部「缓存小说」：整本离线缓存，章节列表复用阅读会话已加载的目录。
  Future<void> _startCaching(ReaderSessionState session) async {
    if (session.chapters.isEmpty) {
      _showMessage('目录还没加载好，请稍后再试');
      return;
    }
    await startOfflineDownload(
      context,
      ref,
      kind: OfflineTaskKind.novel,
      id: widget.args.bookId,
      title: session.bookTitle.isNotEmpty
          ? session.bookTitle
          : widget.args.bookTitle,
      cover: session.cover.isNotEmpty ? session.cover : widget.args.cover,
      items: session.chapters,
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showAppSnackBar(context, message);
  }

  Widget _buildBottomBar(ReaderSettings settings) {
    final paper = settings.paper;
    return IgnorePointer(
      ignoring: !_toolbarVisible,
      child: AnimatedSlide(
        offset: _toolbarVisible ? Offset.zero : const Offset(0, 1.02),
        duration: _toolbarDuration,
        curve: Curves.easeOutCubic,
        child: ReaderBottomBar(
          bottomInset: MediaQuery.paddingOf(context).bottom,
          background: paper.background,
          foreground: paper.foreground,
          isNight: paper == ReaderPaper.night,
          onComments: () => unawaited(_openChapterComments()),
          onDirectory: () => _openDirectory(
            ref.read(readerSessionProvider(widget.args)),
            settings,
            ref.read(readerSessionProvider(widget.args).notifier),
          ),
          onDetail: () =>
              _openDetail(ref.read(readerSessionProvider(widget.args))),
          onToggleDayNight: () =>
              ref.read(readerSettingsProvider.notifier).toggleDayNight(),
          onSettings: _openSettings,
        ),
      ),
    );
  }

  void _openParagraphComments(int paraIndex) {
    final session = ref.read(readerSessionProvider(widget.args));
    final chapter = session.chapterAt(session.contentIndex);
    if (chapter == null) return;
    final ideas =
        ref
            .read(
              chapterIdeasProvider(
                ChapterCommentsArgs(
                  bookId: widget.args.bookId,
                  chapterId: chapter.id,
                  itemVersion: chapter.version,
                ),
              ),
            )
            .value ??
        ChapterIdeas.empty;
    _openCommentsAt(paraIndex, session, ideas);
  }

  /// 工具栏「评论」入口：气泡关闭时没有预取计数，这里按需拉一次再打开。
  Future<void> _openChapterComments() async {
    final session = ref.read(readerSessionProvider(widget.args));
    final chapter = session.chapterAt(session.contentIndex);
    if (chapter == null) return;
    _hideToolbar();
    final args = ChapterCommentsArgs(
      bookId: widget.args.bookId,
      chapterId: chapter.id,
      itemVersion: chapter.version,
    );
    var ideas =
        ref.read(chapterIdeasProvider(args)).value ?? ChapterIdeas.empty;
    if (ideas.isEmpty) {
      // 失败由 provider 归一成 empty；失败就用空结果提示，不打断阅读。
      ideas = await ref.read(chapterIdeasProvider(args).future);
    }
    if (!mounted) return;
    final paraIndex = ideas.chapterEndParaIndex;
    if (paraIndex == null) {
      showAppSnackBar(context, '本章还没有评论');
      return;
    }
    _openCommentsAt(paraIndex, session, ideas);
  }

  /// 打开某一段（或章末聚合桶）的评论面板。
  ///
  /// 段评正文必填 `item_version`，从目录章里取；老目录没有 version 时仍尝试，
  /// 失败由面板自己给「加载失败 + 重试」，不影响阅读。
  void _openCommentsAt(
    int paraIndex,
    ReaderSessionState session,
    ChapterIdeas ideas,
  ) {
    final chapter = session.chapterAt(session.contentIndex);
    if (chapter == null) return;
    _hideToolbar();
    final paper = ref.read(readerSettingsProvider).paper;
    unawaited(
      showReaderCommentsSheet(
        context,
        paper: paper,
        bookId: widget.args.bookId,
        chapterId: chapter.id,
        itemVersion: chapter.version,
        paraIndex: paraIndex,
        title: paraIndex == ideas.chapterEndParaIndex ? '本章评论' : '段评',
        totalCount: ideas.forParagraph(paraIndex)?.count ?? ideas.total,
      ),
    );
  }

  void _openSettings() {
    _hideToolbar();
    final paper = ref.read(readerSettingsProvider).paper;
    showAppBottomSheet<void>(
      context: context,
      builder: (_) =>
          Theme(data: _readerTheme(paper), child: const ReaderSettingsSheet()),
    );
  }

  /// 工具栏「详情」：以底部弹层打开小说详情。
  ///
  /// 弹层里没有主按钮，只留收藏 / 缓存；点目录章节直接跳当前阅读会话，
  /// 不再往栈上叠一个新的阅读页。
  void _openDetail(ReaderSessionState session) {
    final bookId = widget.args.bookId;
    if (bookId.isEmpty) return;
    _hideToolbar();
    final preview = NovelItem(
      id: bookId,
      title: session.bookTitle.isNotEmpty
          ? session.bookTitle
          : widget.args.bookTitle,
      cover: session.cover.isNotEmpty ? session.cover : widget.args.cover,
    );
    unawaited(
      showEmbeddedDetailSheet(
        context: context,
        builder: (_) =>
            DetailPage(bookId: bookId, preview: preview, embed: true),
      ),
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
    showAppBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Theme(
        data: _readerTheme(paper),
        child: ChapterDirectorySheet(
          chapters: session.chapters,
          currentIndex: session.index,
          backgroundColor: paper.background,
          foregroundColor: paper.foreground,
          onSelected: (index) {
            Navigator.of(sheetContext).pop();
            _pendingEntry = null;
            _rememberPosition();
            controller.goToChapter(index);
          },
        ),
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
///
/// 段评部分用**值比较**（bubbleCounts/bubbleVariants 内容相等即视为同一份）：
/// 段评是异步到达的，provider 每次加载都会给新实例，但同一个章的空结果 / 计数
/// 全 0 的结果不应该让已经算好的整章分页作废再排一遍。关气泡时完全忽略 ideas。
@immutable
class _PaginationKey {
  _PaginationKey({
    required this.content,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineHeight,
    required this.fontWeight,
    required this.textScale,
    required this.fontFamily,
    required ChapterIdeas ideas,
    required this.showBubbles,
    required this.showDialogueHighlight,
  }) : bubbleCounts = showBubbles ? ideas.bubbleCounts : const <int, int>{},
       bubbleVariants = showBubbles
           ? ideas.bubbleVariants
           : const <int, ParagraphBubbleVariant>{};

  final ChapterContent content;
  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;

  /// 用实际缩放后的字号代替 TextScaler 对象，避免不同实例但等价时漏复用。
  final double textScale;

  /// 主题字体变了字形度量也会变，必须一起重排。
  final String? fontFamily;

  /// 段评气泡会改变段末折行：只有计数/样式真的变化时才需要重排。
  final Map<int, int> bubbleCounts;
  final Map<int, ParagraphBubbleVariant> bubbleVariants;
  final bool showBubbles;

  /// 对话高亮开关：关掉后分页不做对话扫描/矩形测量，但页数和断行不变；
  /// 开关变化必须重排一次（切换后重排的段落测量几乎全命中缓存）。
  final bool showDialogueHighlight;

  @override
  bool operator ==(Object other) =>
      other is _PaginationKey &&
      identical(other.content, content) &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.fontWeight == fontWeight &&
      other.textScale == textScale &&
      other.fontFamily == fontFamily &&
      mapEquals(other.bubbleCounts, bubbleCounts) &&
      mapEquals(other.bubbleVariants, bubbleVariants) &&
      other.showBubbles == showBubbles &&
      other.showDialogueHighlight == showDialogueHighlight;

  @override
  int get hashCode => Object.hash(
    identityHashCode(content),
    width,
    height,
    fontSize,
    lineHeight,
    fontWeight,
    textScale,
    fontFamily,
    _unorderedMapHash(bubbleCounts),
    _unorderedMapHash(bubbleVariants),
    showBubbles,
    showDialogueHighlight,
  );
}

/// 只由排版输入组成的签名；内容/章评变化不改变它，但字号/宽高/气泡开关
/// 等一变，预排版就必须重算。
@immutable
class _PrepLayout {
  const _PrepLayout({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineHeight,
    required this.fontWeight,
    required this.fontFamily,
    required this.textScaler,
    required this.showBubbles,
    required this.showDialogueHighlight,
  });

  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;
  final String? fontFamily;
  final TextScaler textScaler;
  final bool showBubbles;
  final bool showDialogueHighlight;

  @override
  bool operator ==(Object other) =>
      other is _PrepLayout &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.fontWeight == fontWeight &&
      other.fontFamily == fontFamily &&
      other.textScaler.scale(16) == textScaler.scale(16) &&
      other.showBubbles == showBubbles &&
      other.showDialogueHighlight == showDialogueHighlight;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    fontSize,
    lineHeight,
    fontWeight,
    fontFamily,
    textScaler.scale(16),
    showBubbles,
    showDialogueHighlight,
  );
}

/// 一章的预排版结果：正文、章评汇总、分页，以及生成它的排版签名。
@immutable
class _PreparedChapter {
  const _PreparedChapter({
    required this.chapterId,
    required this.content,
    required this.ideas,
    required this.pagination,
    required this.layout,
  });

  final String chapterId;
  final ChapterContent content;
  final ChapterIdeas ideas;
  final ReaderPagination pagination;
  final _PrepLayout layout;
}

/// Map 的与顺序无关的 hash（兼容 `_PaginationKey` 的值比较）。
int _unorderedMapHash(Map<int, Object?> map) {
  if (map.isEmpty) return 0;
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}
