import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/states.dart';
import '../../data/models/chapter.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/novel_item.dart';
import 'detail_action_bar.dart';
import 'detail_directory_section.dart';
import 'detail_directory_sheet.dart';
import 'detail_hero.dart';
import 'detail_intro_section.dart';
import 'detail_providers.dart';

/// 小说详情页：Hero 信息 + 简介/标签 + 目录 + 底部「开始阅读 / 加入书架」。
///
/// 页面只负责布局与导航；数据、进度、书架状态都在 detail_providers.dart。
/// 构造函数与 router.dart 里的 `DetailArgs` 对应，[preview] 用来在接口返回
/// 前先画封面/标题，避免白屏。
class DetailPage extends ConsumerWidget {
  const DetailPage({super.key, required this.bookId, this.preview});

  final String bookId;
  final NovelItem? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      SliverToBoxAdapter(
        child: DetailHero(detail: detail, preview: preview),
      ),
      if (bundle != null) ...[
        SliverToBoxAdapter(
          child: DetailIntroSection(intro: detail!.abstract, tags: detail.tags),
        ),
        SliverToBoxAdapter(
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
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ] else if (bundleAsync.hasError)
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: _errorMessage(bundleAsync.error!),
            onRetry: () => ref.invalidate(detailBundleProvider(bookId)),
          ),
        )
      else
        const SliverFillRemaining(
          hasScrollBody: false,
          child: LoadingView(label: '正在加载详情…'),
        ),
    ];

    return Scaffold(
      // body 顶到状态栏，Hero 的渐变才能垫在透明 AppBar 后面。
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: CustomScrollView(slivers: slivers),
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
                    )
                  : null,
              shelfLabel: onShelf ? '已在书架' : '加入书架',
              shelfActive: onShelf,
              onShelf: shelfItem == null || shelfBusy
                  ? null
                  : () => _toggleShelf(context, ref, shelfItem),
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

  String _errorMessage(Object error) =>
      error is ApiException ? error.message : '加载失败，请稍后重试';

  /// 打开阅读页；回到详情后刷新「继续阅读 · 第N章」。
  Future<void> _openReader(
    BuildContext context,
    WidgetRef ref, {
    String? chapterId,
    int? chapterIndex,
  }) async {
    final detail = ref.read(detailBundleProvider(bookId)).value?.detail;
    await Navigator.of(context).pushNamed(
      AppRoutes.reader,
      arguments: ReaderArgs(
        bookId: bookId,
        bookTitle: detail?.title ?? preview?.title ?? '',
        cover: detail?.cover ?? preview?.cover ?? '',
        chapterId: chapterId,
        chapterIndex: chapterIndex,
      ),
    );
    if (!context.mounted) return;
    ref.invalidate(detailProgressProvider(bookId));
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
          .read(detailShelfProvider(bookId).notifier)
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
