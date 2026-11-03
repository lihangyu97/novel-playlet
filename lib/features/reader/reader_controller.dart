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

  @override
  ReaderSessionState build() {
    ref.onDispose(() => _disposed = true);
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
      final start = await _resolveStartIndex(chapters, store);
      if (_disposed) return;
      state = state.copyWith(
        chapters: chapters,
        index: start,
        bookTitle: args.bookTitle.isNotEmpty
            ? args.bookTitle
            : (detail?.title ?? ''),
        cover: args.cover.isNotEmpty ? args.cover : (detail?.cover ?? ''),
        loading: true,
        error: null,
      );
      await _loadChapter(start);
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
  Future<int> _resolveStartIndex(
    List<Chapter> chapters,
    ReadingStore store,
  ) async {
    int indexOf(String chapterId) =>
        chapters.indexWhere((chapter) => chapter.id == chapterId);

    final requestedId = args.chapterId;
    if (requestedId != null && requestedId.isNotEmpty) {
      final found = indexOf(requestedId);
      if (found >= 0) return found;
      final fallback = args.chapterIndex;
      if (fallback != null && fallback >= 0 && fallback < chapters.length) {
        return fallback;
      }
      return 0;
    }

    try {
      final progress = await store.progress(args.bookId);
      if (progress != null) {
        if (progress.chapterId.isNotEmpty) {
          final found = indexOf(progress.chapterId);
          if (found >= 0) return found;
        }
        // 目录换源/重排后 chapterId 对不上，退回序号。
        if (progress.chapterIndex >= 0 &&
            progress.chapterIndex < chapters.length) {
          return progress.chapterIndex;
        }
      }
    } catch (_) {
      // 本地进度损坏时从第一章开始。
      return 0;
    }
    return 0;
  }

  Future<void> _loadChapter(int position) async {
    if (_disposed || state.chapters.isEmpty) return;
    final clamped = position.clamp(0, state.chapters.length - 1).toInt();
    final chapter = state.chapters[clamped];
    final token = ++_requestToken;
    state = state.copyWith(index: clamped, loading: true, error: null);
    // 切章即落进度：即使正文请求失败，下次进入也能回到用户想去的那章。
    _saveProgress(chapter);
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
    } catch (error) {
      if (_disposed || token != _requestToken) return;
      state = state.copyWith(
        loading: false,
        error: _messageOf(error, '正文加载失败'),
      );
    }
  }

  Future<void> _saveProgress(Chapter chapter) async {
    try {
      await ref
          .read(readingStoreProvider)
          .saveProgress(
            bookId: args.bookId,
            bookTitle: state.bookTitle,
            cover: state.cover,
            chapterId: chapter.id,
            chapterIndex: chapter.index,
          );
    } catch (_) {
      // 进度是锦上添花，写失败不影响阅读。
      return;
    }
  }

  Future<void> nextChapter() async {
    // 正在加载时忽略重复点击，否则会从"目标章 + 1"再跳一章。
    if (state.loading || !state.hasNext) return;
    await _loadChapter(state.index + 1);
  }

  Future<void> previousChapter() async {
    if (state.loading || !state.hasPrevious) return;
    await _loadChapter(state.index - 1);
  }

  Future<void> goToChapter(int position) async {
    if (_disposed || state.chapters.isEmpty) return;
    final clamped = position.clamp(0, state.chapters.length - 1).toInt();
    if (clamped == state.index && state.loading) return;
    if (clamped == state.index &&
        state.contentIndex == clamped &&
        state.error == null) {
      return;
    }
    await _loadChapter(clamped);
  }

  Future<void> retry() async {
    if (_disposed) return;
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
