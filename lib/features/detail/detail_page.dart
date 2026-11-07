import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/detail/detail_common.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import '../cache/offline_task.dart';
import '../cache/widgets/offline_download_button.dart';
import 'detail_action_bar.dart';
import 'detail_directory_section.dart';
import 'detail_directory_sheet.dart';
import 'detail_hero.dart';
import 'detail_intro_section.dart';
import 'detail_providers.dart';

/// 小说详情页：Hero 信息 + 简介/标签 + 目录 + 底部「开始阅读 / 加入书架」。
///
/// 页面只负责布局与导航；数据、进度、书架状态都在 detail_providers.dart。
/// 构造函数与 router.dart 里的 [DetailRoute] 对应，[preview] 用来在接口返回
/// 前先画封面/标题，避免白屏。
class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({
    super.key,
    required this.bookId,
    this.preview,
    this.heroTag,
  });

  final String bookId;
  final NovelItem? preview;

  /// 封面 Hero tag（列表点进来时由 [DetailRoute] 带下来）；null = 不飞入。
  final String? heroTag;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  final ScrollController _scrollController = ScrollController();
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  /// 滚动后给 AppBar 压上底色：初始透明是为了让 Hero 渐变透出，但一直透明
  /// 会让正文钻到状态栏下面（真机上时间与内容重叠）。
  void _handleScroll() {
    final scrolled =
        _scrollController.hasClients && _scrollController.offset > 10;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    final preview = widget.preview;
    final bundleAsync = ref.watch(detailBundleProvider(bookId));
    final progressAsync = ref.watch(detailProgressProvider(bookId));
    final shelfAsync = ref.watch(detailShelfProvider(bookId));

    // 用 .value 而非 when：刷新时保留上一份数据，页面不闪加载态。
    final bundle = bundleAsync.value;
    final detail = bundle?.detail;
    final chapters = bundle?.chapters ?? const <Chapter>[];
    final progress = progressAsync.value;
    final shelfItem = _resolveShelfItem(bundle, preview);
    final onShelf = shelfAsync.value ?? false;
    final shelfBusy = shelfAsync.isLoading && !shelfAsync.hasValue;

    // 「继续阅读」优先用进度里保存的章（目录顺序变了也还找得到），
    // 没有进度才从第一章开始。
    final resumeChapterId = progress != null && progress.chapterId.isNotEmpty
        ? progress.chapterId
        : null;
    final resumeIndex = progress?.chapterIndex;
    final firstChapter = chapters.isNotEmpty ? chapters.first : null;
    final resumeNumber = progress == null
        ? null
        : (chapters.isEmpty
              ? progress.chapterIndex + 1
              : (progress.chapterIndex + 1).clamp(1, chapters.length));
    final primaryLabel = resumeNumber == null
        ? '开始阅读'
        : '继续阅读 · 第$resumeNumber章';
    final canOpenReader =
        resumeChapterId != null || firstChapter != null || preview != null;

    final slivers = <Widget>[
      // 背景只跟封面走、固定高度：接口回来内容变高也不会牵动它。
      SliverToBoxAdapter(
        child: DetailHeroBackdrop(
          detail: detail,
          preview: preview,
          heroTag: widget.heroTag,
        ),
      ),
      if (bundle != null) ...[
        // 内容就绪后从下方淡入，避免接口回来的瞬间文字凭空跳出。
        SliverToBoxAdapter(
          child: DetailFadeIn(
            child: DetailHeroInfo(detail: detail, preview: preview),
          ),
        ),
        SliverToBoxAdapter(
          child: DetailFadeIn(
            delay: const Duration(milliseconds: 60),
            child: DetailIntroSection(
              intro: detail!.abstract,
              tags: detail.tags,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: DetailFadeIn(
            delay: const Duration(milliseconds: 120),
            child: DetailDirectorySection(
              chapters: chapters,
              currentIndex: progress?.chapterIndex,
              onOpenChapter: (chapter) => _openReader(
                context,
                ref,
                chapterId: chapter.id,
                chapterIndex: chapter.index,
              ),
              onOpenAll: () => _openDirectory(
                context,
                ref,
                chapters: chapters,
                currentIndex: progress?.chapterIndex,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ] else if (bundleAsync.hasError)
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: _errorMessage(bundleAsync.error!),
            onRetry: () => ref.invalidate(detailBundleProvider(bookId)),
          ),
        ),
      // 加载阶段只保留封面背景：不再转圈，内容就绪后直接淡入。
    ];

    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    // 沉浸式顶部：不设 AppBar / 返回按钮（iOS 边缘侧滑返回），Hero 与渐变
    // 直接铺到状态栏后面，内容仍从安全区下方开始。滚动后只叠一层与底色同色
    // 的渐变遮罩，避免正文从状态栏文字下面穿过去。
    final overlayStyle = theme.brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      scheme.primary.withValues(alpha: 0.10),
                      scheme.primary.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.32],
                  ),
                ),
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: slivers,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _scrolled ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Container(
                    height: topInset + 14,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.scaffoldBackgroundColor,
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.92),
                          theme.scaffoldBackgroundColor.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.62, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: (bundle != null || preview != null)
          ? DetailActionBar(
              primaryLabel: primaryLabel,
              onPrimary: canOpenReader
                  ? () => _openReader(
                      context,
                      ref,
                      chapterId: resumeChapterId ?? firstChapter?.id,
                      chapterIndex: resumeChapterId != null
                          ? resumeIndex
                          : firstChapter?.index,
                      // 续读入口带段落落点，回到上次那一页；从头开始读时为 0。
                      blockIndex: resumeChapterId != null
                          ? progress?.blockIndex
                          : 0,
                    )
                  : null,
              shelfLabel: onShelf ? '已收藏' : '收藏',
              shelfActive: onShelf,
              onShelf: shelfItem == null || shelfBusy
                  ? null
                  : () => _toggleShelf(context, ref, shelfItem),
              offlineButton: chapters.isEmpty
                  ? null
                  : OfflineDownloadButton(
                      kind: OfflineTaskKind.novel,
                      id: bookId,
                      title: detail?.title ?? preview?.title ?? '',
                      cover: detail?.cover ?? preview?.cover ?? '',
                      items: chapters,
                    ),
            )
          : null,
    );
  }

  /// 详情里的字段比卡片全，但 bookId 缺失时退回列表卡片。
  NovelItem? _resolveShelfItem(DetailBundle? bundle, NovelItem? preview) {
    final fromDetail = bundle?.shelfItem;
    if (fromDetail != null && fromDetail.isValid) return fromDetail;
    if (preview != null && preview.isValid) return preview;
    return null;
  }

  /// 详情/目录失败文案：统一走 [apiErrorCopy]。
  String _errorMessage(Object error) =>
      apiErrorCopy(error, fallback: '加载失败，请稍后重试');

  /// 打开阅读页；回到详情后刷新「继续阅读 · 第N章」。
  Future<void> _openReader(
    BuildContext context,
    WidgetRef ref, {
    String? chapterId,
    int? chapterIndex,
    int? blockIndex,
  }) async {
    final detail = ref.read(detailBundleProvider(widget.bookId)).value?.detail;
    await context.pushAppRoute(
      ReaderRoute(
        ReaderArgs(
          bookId: widget.bookId,
          bookTitle: detail?.title ?? widget.preview?.title ?? '',
          cover: detail?.cover ?? widget.preview?.cover ?? '',
          chapterId: chapterId,
          chapterIndex: chapterIndex,
          blockIndex: blockIndex,
        ),
      ),
    );
    if (!context.mounted) return;
    ref.invalidate(detailProgressProvider(widget.bookId));
  }

  Future<void> _openDirectory(
    BuildContext context,
    WidgetRef ref, {
    required List<Chapter> chapters,
    int? currentIndex,
  }) async {
    final chapter = await showDetailDirectorySheet(
      context,
      chapters: chapters,
      currentIndex: currentIndex,
    );
    if (!context.mounted || chapter == null) return;
    await _openReader(
      context,
      ref,
      chapterId: chapter.id,
      chapterIndex: chapter.index,
    );
  }

  Future<void> _toggleShelf(
    BuildContext context,
    WidgetRef ref,
    NovelItem item,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final nowOnShelf = await ref
          .read(detailShelfProvider(widget.bookId).notifier)
          .toggle(item);
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(nowOnShelf ? '已加入书架' : '已移出书架'),
            duration: const Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (_) {
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('书架操作失败，请重试'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }
}
