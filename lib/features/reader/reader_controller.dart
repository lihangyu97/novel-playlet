import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/storage/reading_store.dart';
import '../../data/api/api_client.dart';
import '../../data/models/book_detail.dart';
import '../../data/models/chapter.dart';
import '../../data/models/chapter_content.dart';
import '../../data/models/json_utils.dart';
import 'reader_chapter_cache.dart';

/// 阅读会话状态。
///
/// [content] 表示"正在显示的正文"，[contentIndex] 是它所属的章序号。
/// 切章加载期间保留旧 [content] 不动，页面可以继续画上一章的页并叠加
/// 加载提示，不会整页闪白。
@immutable
class ReaderSessionState {
  const ReaderSessionState({
    this.chapters = const <Chapter>[],
    this.index = 0,
    this.content,
    this.contentIndex = -1,
    this.bookTitle = '',
    this.cover = '',
    this.loading = true,
    this.error,
    this.resumeBlockIndex = 0,
    this.resumeChapterIndex = -1,
  });

  final List<Chapter> chapters;

  /// 用户想读的章（点"下一章"后立刻变成目标章）。
  final int index;

  final ChapterContent? content;
  final int contentIndex;
  final String bookTitle;
  final String cover;
  final bool loading;
  final String? error;

  /// 续读入口的落点：当前页首段下标。只有"按本地进度续读"时才有值；
  /// 用户显式点章节进入，或跳过头后会被清成 0。
  final int resumeBlockIndex;

  /// [resumeBlockIndex] 属于哪一章（目录下标）。-1 表示没有待恢复的落点。
  final int resumeChapterIndex;

  bool get hasChapters => chapters.isNotEmpty;

  Chapter? chapterAt(int position) =>
      position >= 0 && position < chapters.length ? chapters[position] : null;

  Chapter? get currentChapter => chapterAt(index);

  /// 正在显示正文的那一章。
  Chapter? get displayedChapter => chapterAt(contentIndex) ?? currentChapter;

  bool get hasNext => index + 1 < chapters.length;

  bool get hasPrevious => index > 0;

  static const Object _unset = Object();

  ReaderSessionState copyWith({
    List<Chapter>? chapters,
    int? index,
    Object? content = _unset,
    int? contentIndex,
    String? bookTitle,
    String? cover,
    bool? loading,
    Object? error = _unset,
    int? resumeBlockIndex,
    int? resumeChapterIndex,
  }) => ReaderSessionState(
    chapters: chapters ?? this.chapters,
    index: index ?? this.index,
    content: identical(content, _unset)
        ? this.content
        : content as ChapterContent?,
    contentIndex: contentIndex ?? this.contentIndex,
    bookTitle: bookTitle ?? this.bookTitle,
    cover: cover ?? this.cover,
    loading: loading ?? this.loading,
    error: identical(error, _unset) ? this.error : error as String?,
    resumeBlockIndex: resumeBlockIndex ?? this.resumeBlockIndex,
    resumeChapterIndex: resumeChapterIndex ?? this.resumeChapterIndex,
  );
}

/// 阅读页控制器。
///
/// 入参作为 family 的 key：阅读页在一次路由生命周期里只有一份 [ReaderArgs]，
/// 身份固定，不需要额外做值相等。
final readerSessionProvider = NotifierProvider.autoDispose
    .family<ReaderController, ReaderSessionState, ReaderArgs>(
      ReaderController.new,
    );

class ReaderController extends Notifier<ReaderSessionState> {
  ReaderController(this.args);

  final ReaderArgs args;

  bool _disposed = false;
  bool _bootstrapping = false;
  int _requestToken = 0;

  /// 页级进度防抖：翻页很频繁，没必要每一页都写一次 SharedPreferences。
  Timer? _progressTimer;
  int? _pendingBlockIndex;
  static const Duration _progressDebounce = Duration(milliseconds: 400);

  late ReaderChapterCache _cache;

  /// 下一章/上一章的后台预取队列。并发上限 1，避免快速滑动时打爆请求。
  final List<Chapter> _prefetchQueue = <Chapter>[];
  final Set<String> _prefetchQueued = <String>{};
  final Set<String> _prefetching = <String>{};
  final Set<String> _prefetched = <String>{};
  bool _prefetchWorkerRunning = false;
  static const int _maxPrefetchQueue = 4;

  @override
  ReaderSessionState build() {
    ref.onDispose(() {
      _disposed = true;
      _progressTimer?.cancel();
      _progressTimer = null;
    });
    _cache = ref.read(readerChapterCacheProvider);
    // 目录与正文都是网络请求，不能阻塞 build；先给加载态，回来后刷新。
    _bootstrap();
    return ReaderSessionState(bookTitle: args.bookTitle, cover: args.cover);
  }

  Future<void> _bootstrap() async {
    if (_bootstrapping) return;
    _bootstrapping = true;
    try {
      final api = ref.read(apiClientProvider);
      final store = ref.read(readingStoreProvider);
      // 详情和目录并行：详情只用来补书名/封面，失败不影响阅读。
      final detailFuture = _loadDetail(api);
      final chapters = await api.directory(args.bookId);
      final detail = await detailFuture;
      if (_disposed) return;
      if (chapters.isEmpty) {
        state = state.copyWith(
          chapters: const <Chapter>[],
          loading: false,
          error: '目录为空',
        );
        return;
      }
      final start = await _resolveStart(chapters, store);
      if (_disposed) return;
      state = state.copyWith(
        chapters: chapters,
        index: start.index,
        resumeBlockIndex: start.blockIndex,
        resumeChapterIndex: start.blockIndex > 0 ? start.index : -1,
        bookTitle: args.bookTitle.isNotEmpty
            ? args.bookTitle
            : (detail?.title ?? ''),
        cover: args.cover.isNotEmpty ? args.cover : (detail?.cover ?? ''),
        loading: true,
        error: null,
      );
      await _loadChapter(start.index);
    } catch (error) {
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        error: _messageOf(error, '目录加载失败'),
      );
    } finally {
      _bootstrapping = false;
    }
  }

  Future<BookDetail?> _loadDetail(ApiClient api) async {
    if (args.bookTitle.isNotEmpty && args.cover.isNotEmpty) return null;
    try {
      return await api.bookDetail(args.bookId);
    } catch (_) {
      // 书名/封面只是装饰，拿不到就用入参里的值，不阻断阅读。
      return null;
    }
  }

  /// 起始章优先级：显式指定的章 > 本地进度 > 第一章。
  ///
  /// 只有走到"本地进度"这一路才带回 `blockIndex`：显式点章节进入是从页首
  /// 开始读，不该跳到上次停下的段落。
  Future<({int index, int blockIndex})> _resolveStart(
    List<Chapter> chapters,
    ReadingStore store,
  ) async {
    int indexOf(String chapterId) =>
        chapters.indexWhere((chapter) => chapter.id == chapterId);

    final requestedId = args.chapterId;
    if (requestedId != null && requestedId.isNotEmpty) {
      // 入口可以同时指定章与段落落点：详情页「继续阅读」/「我的」最近阅读
      // 就是这么进来的，不带 blockIndex 时才从页首开始（用户主动点某章）。
      final requestedBlock = (args.blockIndex ?? 0).clamp(0, 1 << 30);
      final found = indexOf(requestedId);
      if (found >= 0) return (index: found, blockIndex: requestedBlock);
      final fallback = args.chapterIndex;
      if (fallback != null && fallback >= 0 && fallback < chapters.length) {
        return (index: fallback, blockIndex: requestedBlock);
      }
      return (index: 0, blockIndex: 0);
    }

    try {
      final progress = await store.progress(args.bookId);
      if (progress != null) {
        final blockIndex = progress.blockIndex < 0 ? 0 : progress.blockIndex;
        if (progress.chapterId.isNotEmpty) {
          final found = indexOf(progress.chapterId);
          if (found >= 0) return (index: found, blockIndex: blockIndex);
        }
        // 目录换源/重排后 chapterId 对不上，退回序号。
        if (progress.chapterIndex >= 0 &&
            progress.chapterIndex < chapters.length) {
          return (index: progress.chapterIndex, blockIndex: blockIndex);
        }
      }
    } catch (_) {
      // 本地进度损坏时从第一章开始。
      return (index: 0, blockIndex: 0);
    }
    return (index: 0, blockIndex: 0);
  }

  Future<void> _loadChapter(int position) async {
    if (_disposed || state.chapters.isEmpty) return;
    final clamped = position.clamp(0, state.chapters.length - 1).toInt();
    final chapter = state.chapters[clamped];
    final token = ++_requestToken;

    // 切章前先把上一章最后一次翻页的兜底进度落盘（防抖可能还没到点）。
    _flushPendingProgress();

    final resumeChapterIndex = state.resumeChapterIndex;
    final resumeBlockIndex = state.resumeBlockIndex;
    final leavesResumeEntry =
        resumeChapterIndex >= 0 && clamped != resumeChapterIndex;
    // 目标章立刻生效（工具栏/进度用）；正文等缓存或请求回来再换。
    state = state.copyWith(
      index: clamped,
      error: null,
      // 跳到别的章后，原来的续读落点就失效了，别影响后续进入本章。
      resumeBlockIndex: leavesResumeEntry ? 0 : resumeBlockIndex,
      resumeChapterIndex: leavesResumeEntry ? -1 : resumeChapterIndex,
    );
    // 切章即落进度：即使正文请求失败，下次进入也能回到用户想去的那章。
    // 续读入口这一章要保住 blockIndex，否则第二次进来又回到页首。
    final resumeBlock = resumeChapterIndex == clamped ? resumeBlockIndex : 0;
    _saveProgress(chapter, blockIndex: resumeBlock);

    // 命中本地缓存就直接展示，连 loading 态都不进，才不会闪一下。
    final cached = await _cache.get(chapter.id);
    if (_disposed || token != _requestToken) return;
    if (cached != null) {
      state = state.copyWith(
        content: cached.content,
        contentIndex: clamped,
        loading: false,
        error: null,
      );
      // 超过 7 天的旧正文仍先展示，同时悄悄刷新一次缓存。
      if (cached.isStale) _enqueuePrefetch(chapter);
      _prefetchNeighbors();
      return;
    }

    state = state.copyWith(loading: true);
    try {
      final content = await ref
          .read(apiClientProvider)
          .chapter(chapter.id, title: chapter.title);
      if (_disposed || token != _requestToken) return;
      state = state.copyWith(
        content: content,
        contentIndex: clamped,
        loading: false,
        error: null,
      );
      unawaited(_cache.put(content));
      _prefetchNeighbors();
    } catch (error) {
      if (_disposed || token != _requestToken) return;
      state = state.copyWith(
        loading: false,
        error: _messageOf(error, '正文加载失败'),
      );
    }
  }

  /// 当前章展示后，把相邻章悄悄拉进本地缓存。只写缓存，不动 UI 状态，
  /// 避免预取结果串到正在显示的章节上。
  void _prefetchNeighbors() {
    final chapters = state.chapters;
    if (chapters.isEmpty) return;
    final next = state.index + 1;
    if (next < chapters.length) _enqueuePrefetch(chapters[next]);
    final previous = state.index - 1;
    if (previous >= 0) _enqueuePrefetch(chapters[previous]);
  }

  void _enqueuePrefetch(Chapter chapter) {
    final id = chapter.id;
    if (id.isEmpty) return;
    if (_prefetched.contains(id) ||
        _prefetching.contains(id) ||
        _prefetchQueued.contains(id)) {
      return;
    }
    // 快速连续切章时只保留最近几章，别让旧目标越排越多。
    while (_prefetchQueue.length >= _maxPrefetchQueue) {
      final dropped = _prefetchQueue.removeAt(0);
      _prefetchQueued.remove(dropped.id);
    }
    _prefetchQueue.add(chapter);
    _prefetchQueued.add(id);
    unawaited(_drainPrefetchQueue());
  }

  Future<void> _drainPrefetchQueue() async {
    if (_prefetchWorkerRunning) return;
    _prefetchWorkerRunning = true;
    try {
      while (_prefetchQueue.isNotEmpty) {
        final chapter = _prefetchQueue.removeAt(0);
        _prefetchQueued.remove(chapter.id);
        await _fetchIntoCache(chapter);
        if (_disposed) return;
      }
    } finally {
      _prefetchWorkerRunning = false;
    }
  }

  Future<void> _fetchIntoCache(Chapter chapter) async {
    final id = chapter.id;
    if (_disposed || id.isEmpty) return;
    if (_prefetched.contains(id) || _prefetching.contains(id)) return;
    _prefetching.add(id);
    try {
      final cached = await _cache.get(id);
      if (_disposed) return;
      // 已有新鲜缓存（含之前预取过的）就不再请求。
      if (cached != null && !cached.isStale) {
        _prefetched.add(id);
        return;
      }
      // miss 或已过期才请求；过期时 UI 仍用旧内容，这里只刷新磁盘。
      final content = await ref
          .read(apiClientProvider)
          .chapter(id, title: chapter.title);
      if (_disposed) return;
      await _cache.put(content);
      _prefetched.add(id);
    } catch (_) {
      // 预取失败静默丢弃：真正切到该章时会走正常请求（离线时也能用旧缓存）。
      return;
    } finally {
      _prefetching.remove(id);
    }
  }

  Future<void> _saveProgress(Chapter chapter, {int blockIndex = 0}) async {
    try {
      await ref
          .read(readingStoreProvider)
          .saveProgress(
            bookId: args.bookId,
            bookTitle: state.bookTitle,
            cover: state.cover,
            chapterId: chapter.id,
            chapterIndex: chapter.index,
            blockIndex: blockIndex < 0 ? 0 : blockIndex,
          );
    } catch (_) {
      // 进度是锦上添花，写失败不影响阅读。
      return;
    }
  }

  /// 页面报告"当前页首段下标"，400ms 防抖后落盘；切章/退出时立即 flush。
  void noteReadingBlock(int blockIndex) {
    if (_disposed) return;
    final chapter = state.chapterAt(state.contentIndex);
    if (chapter == null || blockIndex < 0) return;
    _pendingBlockIndex = blockIndex;
    _progressTimer?.cancel();
    _progressTimer = Timer(_progressDebounce, _flushPendingProgress);
  }

  /// 立即把待落盘的页级进度写掉（切章、页面 dispose 前调用）。
  void flushPendingProgress() => _flushPendingProgress();

  /// 仅取消防抖计时器，不碰 provider state：页面 dispose 时 provider 可能
  /// 已经在销毁流程里，不能安全读取 state。
  void cancelProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _flushPendingProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    final blockIndex = _pendingBlockIndex;
    _pendingBlockIndex = null;
    if (blockIndex == null || _disposed) return;
    final chapter = state.chapterAt(state.contentIndex);
    if (chapter == null) return;
    _saveProgress(chapter, blockIndex: blockIndex);
  }

  /// 续读落点已由页面消费时调用，避免重排/重进时重复跳页。
  void clearResumeBlock() {
    if (state.resumeBlockIndex == 0 && state.resumeChapterIndex < 0) return;
    state = state.copyWith(resumeBlockIndex: 0, resumeChapterIndex: -1);
  }

  /// 是否正在切章。缓存命中的那一小段窗口里 [ReaderSessionState.loading]
  /// 还没置位（命中就不该闪 loading），但 index 已指向目标章、正文还是旧的；
  /// 此时再点"下一章"必须忽略，否则会从目标章再 +1 一次跳两章。
  bool get _switching =>
      state.loading ||
      (state.error == null && state.index != state.contentIndex);

  Future<void> nextChapter() async {
    if (_switching || !state.hasNext) return;
    await _loadChapter(state.index + 1);
  }

  Future<void> previousChapter() async {
    if (_switching || !state.hasPrevious) return;
    await _loadChapter(state.index - 1);
  }

  Future<void> goToChapter(int position) async {
    if (_disposed || state.chapters.isEmpty || _switching) return;
    final clamped = position.clamp(0, state.chapters.length - 1).toInt();
    if (clamped == state.index &&
        state.contentIndex == clamped &&
        state.error == null) {
      return;
    }
    await _loadChapter(clamped);
  }

  Future<void> retry() async {
    if (_disposed || _switching) return;
    if (state.chapters.isEmpty) {
      state = state.copyWith(loading: true, error: null);
      await _bootstrap();
      return;
    }
    await _loadChapter(state.index);
  }

  String _messageOf(Object error, String fallback) =>
      error is ApiException ? error.message : fallback;
}
