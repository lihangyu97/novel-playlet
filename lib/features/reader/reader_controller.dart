import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/storage/offline/offline_book.dart';
import '../../core/storage/offline/offline_book_store.dart';
import '../../core/storage/reading_store.dart';
import '../../data/api/api_client.dart';
import '../../data/models/book_detail.dart';
import '../../data/models/chapter.dart';
import '../../data/models/chapter_content.dart';
import '../../data/models/json_utils.dart';
import '../cache/cache_providers.dart';
import 'reader_chapter_cache.dart';
import 'reader_settings.dart';

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
    this.failedIndex = -1,
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

  /// 最近一次加载失败的章（目录下标）；-1 表示没有。
  ///
  /// 已经读到正文时失败不会清空页面：`index` 会退回正在显示的章，失败目标
  /// 单独记在这里，供顶部提示条的「重试」定位到正确章节。
  final int failedIndex;

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
    Object? failedIndex = _unset,
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
    failedIndex: identical(failedIndex, _unset)
        ? this.failedIndex
        : failedIndex as int,
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

  /// 小说离线 pinned 区（整本下载落盘的目录 + 正文）。
  ///
  /// 阅读链路按 offline → 自动缓存 → 网络 的顺序取正文，见
  /// docs/implementation.md；它只被用户手动删除，阅读页不会写它。
  late OfflineBookStore _offline;

  /// 下一章/上一章的后台预取队列。并发上限 1，避免快速滑动时打爆请求。
  final List<Chapter> _prefetchQueue = <Chapter>[];
  final Set<String> _prefetchQueued = <String>{};
  final Set<String> _prefetching = <String>{};
  final Set<String> _prefetched = <String>{};
  bool _prefetchWorkerRunning = false;
  static const int _maxPrefetchQueue = 4;

  /// 缺段落锚点的老缓存/老离线正文：同一章每次会话只补取一次，避免纯文本源
  /// 反复请求。
  final Set<String> _anchorUpgradeTried = <String>{};

  /// 会话内补到锚点的正文（按 chapterId）。
  ///
  /// 离线章节的补取结果只放这里：不写离线 pinned 区、也不写自动缓存，但同一
  /// 次阅读里切走再回来仍要能画气泡，否则每次重进都回落到无锚点的离线正文。
  final Map<String, ChapterContent> _anchoredChapters =
      <String, ChapterContent>{};

  @override
  ReaderSessionState build() {
    ref.onDispose(() {
      _disposed = true;
      _progressTimer?.cancel();
      _progressTimer = null;
    });
    _cache = ref.read(readerChapterCacheProvider);
    _offline = ref.read(offlineBookStoreProvider);
    // 目录与正文都是网络请求，不能阻塞 build；先给加载态，回来后刷新。
    _bootstrap();
    return ReaderSessionState(bookTitle: args.bookTitle, cover: args.cover);
  }

  Future<void> _bootstrap() async {
    if (_bootstrapping) return;
    _bootstrapping = true;
    try {
      final store = ref.read(readingStoreProvider);
      // 离线优先：整本下载过（有 book.json）就直接用本地目录进阅读，不等网络。
      // 没有离线内容时保持原来的网络优先路径。
      final offline = await _readOfflineBook();
      if (_disposed) return;
      if (offline != null && offline.chapters.isNotEmpty) {
        final chapters = _chaptersFromOffline(offline);
        final start = await _resolveStart(chapters, store);
        if (_disposed) return;
        state = state.copyWith(
          chapters: chapters,
          index: start.index,
          resumeBlockIndex: start.blockIndex,
          resumeChapterIndex: start.blockIndex > 0 ? start.index : -1,
          bookTitle: args.bookTitle.isNotEmpty ? args.bookTitle : offline.title,
          cover: args.cover.isNotEmpty ? args.cover : offline.cover,
          loading: true,
          error: null,
        );
        // 先把正文放出来（离线命中不进 loading），再后台静默刷新目录。
        await _loadChapter(start.index);
        if (_disposed) return;
        unawaited(_refreshDirectoryInBackground());
        return;
      }
      await _bootstrapFromNetwork(store);
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

  /// 没有离线 manifest 时的原路径：目录 + 详情并行网络请求。
  ///
  /// 失败交给 [_bootstrap] 统一置错误态——未缓存的书断网时保持现有错误页，
  /// 不会因为"离线兜底"而变成空白。
  Future<void> _bootstrapFromNetwork(ReadingStore store) async {
    final api = ref.read(apiClientProvider);
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
  }

  /// 读整本离线 manifest；不存在/损坏/存储不可用都当没有（离线只是兜底）。
  Future<OfflineBook?> _readOfflineBook() async {
    try {
      return await ref.read(offlineNovelProvider(args.bookId).future);
    } catch (_) {
      return null;
    }
  }

  /// manifest 章节 → 阅读器目录。
  ///
  /// 序号按数组顺序重排：manifest 的 index 是下载时目录的下标，换源/重排后
  /// 可能重复或间断；阅读器只依赖列表相对顺序，用当前位置最稳。
  List<Chapter> _chaptersFromOffline(OfflineBook book) => [
    for (var i = 0; i < book.chapters.length; i++)
      Chapter(
        id: book.chapters[i].id,
        title: book.chapters[i].title,
        volumeName: book.chapters[i].volumeName,
        index: i,
      ),
  ];

  /// 有离线目录时后台刷新网络目录：成功后按 chapterId 保持当前章替换，失败
  /// （断网/上游异常）静默保留本地目录，绝不清掉已经渲染出来的内容。
  Future<void> _refreshDirectoryInBackground() async {
    try {
      final api = ref.read(apiClientProvider);
      final detailFuture = _loadDetail(api);
      final chapters = await api.directory(args.bookId);
      final detail = await detailFuture;
      if (_disposed || chapters.isEmpty) return;

      final before = state;
      final targetId = before.chapterAt(before.index)?.id ?? '';
      final displayedId = before.chapterAt(before.contentIndex)?.id ?? '';
      final targetIndex = targetId.isEmpty
          ? -1
          : chapters.indexWhere((chapter) => chapter.id == targetId);
      // 找不到当前章（目录整体换源/换 id）时不拿旧下标硬套，保留本地目录。
      if (targetIndex < 0) return;
      final displayedIndex = displayedId.isEmpty
          ? -1
          : chapters.indexWhere((chapter) => chapter.id == displayedId);
      state = state.copyWith(
        chapters: chapters,
        index: targetIndex,
        contentIndex: displayedIndex,
        bookTitle: args.bookTitle.isNotEmpty
            ? args.bookTitle
            : (detail?.title ?? before.bookTitle),
        cover: args.cover.isNotEmpty
            ? args.cover
            : (detail?.cover ?? before.cover),
      );
      if (displayedIndex < 0) {
        // 正在显示的章不在新目录里：按新目录重新加载目标章正文。
        await _loadChapter(targetIndex);
      }
    } catch (_) {
      // 断网/接口失败：静默保留本地目录，用户仍能继续读离线内容。
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
      failedIndex: -1,
      // 跳到别的章后，原来的续读落点就失效了，别影响后续进入本章。
      resumeBlockIndex: leavesResumeEntry ? 0 : resumeBlockIndex,
      resumeChapterIndex: leavesResumeEntry ? -1 : resumeChapterIndex,
    );
    // 切章即落进度：即使正文请求失败，下次进入也能回到用户想去的那章。
    // 续读入口这一章要保住 blockIndex，否则第二次进来又回到页首。
    final resumeBlock = resumeChapterIndex == clamped ? resumeBlockIndex : 0;
    _saveProgress(chapter, blockIndex: resumeBlock);

    // 1) 离线 pinned 层优先：整本下载过的正文直接展示，连 loading 都不进。
    //    离线内容不回写自动缓存——离线区是最终数据源；缺段落锚点时只补取
    //    网络正文用于显示/段评，不覆盖离线数据。
    final offline = await _readOfflineChapter(chapter.id);
    if (_disposed || token != _requestToken) return;
    if (offline != null) {
      final upgraded = _anchoredChapters[chapter.id];
      _applyContent(chapter, upgraded ?? offline);
      // 升级前下载的离线章节没有段落锚点：在线时补取一次带锚点的正文。
      // 结果只用于当前显示/段评并记在会话里，不覆盖离线 pinned 区。
      if (upgraded == null && offline.paraIndices.isEmpty) {
        unawaited(_upgradeAnchors(chapter, writeCache: false));
      }
      _prefetchNeighbors();
      return;
    }

    // 2) 自动加速层：命中就直接展示，连 loading 态都不进，才不会闪一下。
    final cached = await _cache.get(chapter.id);
    if (_disposed || token != _requestToken) return;
    if (cached != null) {
      _applyContent(chapter, cached.content);
      // 老 schema 缓存没有段落锚点：后台补取一次并回填当前章，别让段评
      // 一直等到 7 天过期才出现；补取本身也会刷新过期缓存，不再重复请求。
      if (cached.anchorsOutdated &&
          ref.read(readerSettingsProvider).showBubbles) {
        unawaited(_upgradeAnchors(chapter));
      } else if (cached.isStale) {
        // 超过 7 天的旧正文仍先展示，同时悄悄刷新一次缓存。
        _enqueuePrefetch(chapter);
      }
      _prefetchNeighbors();
      return;
    }

    // 3) 网络。
    state = state.copyWith(loading: true);
    try {
      final content = await ref
          .read(apiClientProvider)
          .chapter(chapter.id, title: chapter.title);
      if (_disposed || token != _requestToken) return;
      _applyContent(chapter, content);
      unawaited(_cache.put(content));
      _prefetchNeighbors();
    } catch (error) {
      if (_disposed || token != _requestToken) return;
      // 已经读到正文时不要整页报错：保留正在显示的章，错误降级成顶部提示条。
      // index 退回 contentIndex，信息条/上下章/目录都和实际正文保持一致；
      // 失败目标记到 failedIndex，提示条「重试」据此定位。
      final hasVisibleContent =
          state.content != null && state.contentIndex >= 0;
      state = state.copyWith(
        index: hasVisibleContent ? state.contentIndex : clamped,
        loading: false,
        error: _messageOf(error, '正文加载失败'),
        failedIndex: clamped,
      );
    }
  }

  /// 正文就绪：按 chapterId 找回它在当前目录里的位置再落地。
  ///
  /// 后台刷新目录可能刚好在请求期间把 chapters 换掉，沿用旧下标会把内容挂到
  /// 别的章上；找不到这一章（换源）时丢弃结果，不张冠李戴。
  void _applyContent(Chapter chapter, ChapterContent content) {
    final position = state.chapters.indexWhere((item) => item.id == chapter.id);
    if (position < 0) {
      state = state.copyWith(loading: false);
      return;
    }
    state = state.copyWith(
      content: content,
      contentIndex: position,
      loading: false,
      error: null,
      failedIndex: -1,
    );
  }

  /// 读一章离线正文；失败/损坏都当 miss（自动层与网络会继续兜底）。
  Future<ChapterContent?> _readOfflineChapter(String chapterId) async {
    try {
      return await _offline.readChapter(args.bookId, chapterId);
    } catch (_) {
      return null;
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
      // 离线区已有这一章就不再请求，也不写自动缓存（pinned 层优先）。
      if (await _readOfflineChapter(id) != null) {
        _prefetched.add(id);
        return;
      }
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

  /// 阅读页在「气泡开启、但当前正文没有段落锚点」时调用（含设置里重新打开
  /// 气泡）：同一章只补取一次，避免纯文本源反复发请求。
  void ensureAnchorUpgrade() {
    final chapter = state.chapterAt(state.contentIndex);
    final content = state.content;
    if (chapter == null || content == null) return;
    // 空列表 = 老缓存/老离线文件没写过锚点字段，需要补取；全 null 的列表
    // （纯文本源）是已经取回的正文，不再为它发请求。
    if (content.paraIndices.isNotEmpty) return;
    unawaited(_upgradeAnchors(chapter));
  }

  /// 老版本写入的缓存/离线正文没有段落锚点（正文 `<p idx>`），段评气泡因此
  /// 永远画不出来：这里后台补取一次，拿到**真锚点**后替换当前显示（只在用户
  /// 还停在这一章时），并按 [writeCache] 决定是否写回自动缓存。
  ///
  /// - 纯文本源补取回来仍没有锚点：不替换正文；自动缓存来源写回带 `v` 的新
  ///   缓存后不再重试，离线来源不写（离线正文是用户数据）。
  /// - 段评气泡关闭时不发请求（与「关气泡 = 0 请求」的约定一致）；冷启动要
  ///   等本地偏好恢复，避免拿默认值误判。
  Future<void> _upgradeAnchors(
    Chapter chapter, {
    bool writeCache = true,
  }) async {
    final id = chapter.id;
    if (_disposed || id.isEmpty) return;
    final settings = ref.read(readerSettingsProvider.notifier);
    if (!settings.isRestored) await settings.restoreFuture;
    if (_disposed) return;
    if (!ref.read(readerSettingsProvider).showBubbles) return;
    if (!_anchorUpgradeTried.add(id)) return;
    final token = _requestToken;
    try {
      final content = await ref
          .read(apiClientProvider)
          .chapter(id, title: chapter.title);
      if (_disposed) return;
      if (content.hasAnchors) {
        _anchoredChapters[id] = content;
      }
      if (writeCache) {
        // 无论有没有锚点都写回：带 `v` 的新 schema 会阻止下次再试。
        unawaited(_cache.put(content));
      }
      if (!content.hasAnchors || token != _requestToken) return;
      final position = state.chapters.indexWhere((item) => item.id == id);
      if (position < 0 || state.index != position) return;
      // 有失败提示条时不动 state，避免把「重试」的目标章一起清掉。
      if (state.error != null) return;
      _applyContent(chapter, content);
    } catch (_) {
      // 断网/上游失败：保留原正文继续读，下次进本章再试。
      _anchorUpgradeTried.remove(id);
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
    // 失败时 index 已经退回正在显示的章，真正要重试的是 failedIndex。
    final target = state.failedIndex >= 0 ? state.failedIndex : state.index;
    await _loadChapter(target);
  }

  /// 关闭「正文加载失败」提示条：只清错误，不重新请求。
  ///
  /// 只有已经读到正文时才允许关闭；首次进入就失败（content 为空）必须保留
  /// 整页错误态，否则关掉后会停在无内容的空白页。
  void dismissError() {
    if (state.error == null || state.content == null) return;
    state = state.copyWith(error: null, failedIndex: -1);
  }

  /// 目录/正文失败文案：统一走 [apiErrorCopy]（具体原因优先，技术兜底换短句）。
  String _messageOf(Object error, String fallback) =>
      apiErrorCopy(error, fallback: fallback);
}
