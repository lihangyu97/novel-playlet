import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读页离线优先链路（docs/implementation.md）。
///
/// 用临时目录 + 内存缓存放真实的 `OfflineBookStore` / `ReaderChapterCache`，
/// 只把网络换成可编排的假 transport：
/// - 有 manifest 且断网 → 直接进阅读、可切章；
/// - 在线时后台刷新目录，按 chapterId 保持当前章；
/// - 正文读取顺序 offline → 自动缓存 → 网络，离线命中不写自动缓存。
void main() {
  late Directory tempRoot;
  late OfflinePaths paths;
  late OfflineBookStore store;
  late _RecordingChapterCache cache;
  late _OfflineTransport transport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('reader_offline_test_');
    paths = OfflinePaths(rootDirectory: () async => tempRoot);
    store = OfflineBookStore(paths: paths);
    cache = _RecordingChapterCache();
    transport = _OfflineTransport();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
  });

  /// 写入 manifest（`ids` 是要下载的完整目录）与其中一部分正文。
  Future<void> seedOffline({
    String bookId = '1',
    String title = '离线书',
    List<String> ids = const ['c0', 'c1', 'c2'],
    Set<String> withContent = const {'c0', 'c1', 'c2'},
  }) async {
    await store.begin(
      OfflineBook(
        bookId: bookId,
        title: title,
        cover: 'https://example.com/offline-cover.jpg',
        chapters: [
          for (var i = 0; i < ids.length; i++)
            OfflineChapter(id: ids[i], title: '离线第${i + 1}章', index: i),
        ],
        completed: withContent.length,
      ),
    );
    for (final id in withContent) {
      await store.writeChapter(
        bookId,
        ChapterContent(id: id, title: '离线$id', paragraphs: ['离线正文 $id']),
      );
    }
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(transport)),
        offlinePathsProvider.overrideWithValue(paths),
        readerChapterCacheProvider.overrideWithValue(cache),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 建会话并保持 autoDispose provider 存活，然后等状态满足 [ready]。
  Future<ReaderSessionState> openSession(
    ProviderContainer container,
    ReaderArgs args, {
    required bool Function(ReaderSessionState state) ready,
    String reason = '',
  }) async {
    container.listen(
      readerSessionProvider(args),
      (_, _) {},
      fireImmediately: true,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      final state = container.read(readerSessionProvider(args));
      if (ready(state)) return state;
      if (DateTime.now().isAfter(deadline)) {
        fail(
          '等待阅读会话超时（$reason）：index=${state.index} '
          'contentIndex=${state.contentIndex} loading=${state.loading} '
          'error=${state.error}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('有离线 manifest 且断网：直接进阅读并可切章', () async {
    await seedOffline();
    transport.failing = true;
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '离线书');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
      reason: '离线正文应直接展示',
    );
    expect(session.chapters.map((chapter) => chapter.id), ['c0', 'c1', 'c2']);
    expect(session.content!.paragraphs, ['离线正文 c0']);
    expect(session.displayedChapter!.id, 'c0');
    expect(session.error, isNull);
    expect(transport.directoryCalls, hasLength(1), reason: '仍会尝试后台刷新目录');

    final controller = container.read(readerSessionProvider(args).notifier);
    await controller.nextChapter();
    final next = await openSession(
      container,
      args,
      ready: (state) => state.contentIndex == 1 && !state.loading,
      reason: '离线切章',
    );
    expect(next.displayedChapter!.id, 'c1');
    expect(next.content!.paragraphs, ['离线正文 c1']);
    expect(next.error, isNull);

    // 刷新失败必须静默：断网时目录仍用离线那份，不能被清空成错误态。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(container.read(readerSessionProvider(args)).chapters, hasLength(3));
    expect(container.read(readerSessionProvider(args)).error, isNull);
  });

  test('在线时后台刷新目录，按 chapterId 保持当前章', () async {
    await seedOffline();
    transport
      ..directoryIds = ['c9', 'c0', 'c1', 'c2']
      ..directoryDelay = const Duration(milliseconds: 40);
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '离线书', chapterId: 'c1');

    final local = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
      reason: '先出离线正文',
    );
    expect(local.chapters, hasLength(3), reason: '网络目录还没回来，先用本地目录');
    expect(local.displayedChapter!.id, 'c1');

    final refreshed = await openSession(
      container,
      args,
      ready: (state) => state.chapters.length == 4,
      reason: '后台刷新目录',
    );
    expect(refreshed.index, 2, reason: 'c1 在新目录里的下标是 2');
    expect(refreshed.contentIndex, 2, reason: '正文仍是 c1，下标要跟着目录一起改');
    expect(refreshed.displayedChapter!.id, 'c1');
    expect(refreshed.content!.paragraphs, ['离线正文 c1'], reason: '刷新目录不能丢正文');
    expect(refreshed.error, isNull);
  });

  test('离线正文优先于自动缓存，且离线命中不写自动缓存', () async {
    await seedOffline(ids: const ['c0'], withContent: const {'c0'});
    cache.memory['c0'] = const ChapterContent(
      id: 'c0',
      title: '自动缓存',
      paragraphs: ['自动缓存正文'],
    );
    transport.failing = true;
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '离线书');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
    );
    expect(session.content!.paragraphs, ['离线正文 c0'], reason: 'offline 在自动缓存之前');
    // 等后台刷新（失败）与相邻章预取都跑完，再断言没有写自动缓存。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(cache.puts, isEmpty);
  });

  test('离线整本只下了一部分：缺失章回退自动缓存', () async {
    await seedOffline(ids: const ['c0', 'c1'], withContent: const {'c0'});
    cache.memory['c1'] = const ChapterContent(
      id: 'c1',
      title: '自动缓存',
      paragraphs: ['自动缓存正文 c1'],
    );
    transport.failing = true;
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '离线书', chapterId: 'c1');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
    );
    expect(session.content!.paragraphs, ['自动缓存正文 c1']);
    expect(cache.puts, isEmpty, reason: '自动缓存命中不需要回写');
    expect(transport.chapterCalls, isEmpty, reason: '断网时不应再等网络');
  });

  test('在线取到正文后照旧写自动缓存', () async {
    transport
      ..directoryIds = ['c0', 'c1']
      ..chapterParagraphs['c0'] = ['网络正文 c0'];
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '在线书');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
    );
    expect(session.chapters.map((chapter) => chapter.id), ['c0', 'c1']);
    expect(session.content!.paragraphs, ['网络正文 c0']);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(cache.puts, contains('c0'));
  });

  test('没有离线 manifest 且断网：保持现有错误态', () async {
    transport.failing = true;
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '未缓存');

    final session = await openSession(
      container,
      args,
      ready: (state) => !state.loading && state.error != null,
    );
    expect(session.chapters, isEmpty);
    expect(session.error, isNotNull);
  });

  test('切章失败保留正在显示的正文，错误降级为提示条', () async {
    transport
      ..directoryIds = ['c0', 'c1', 'c2']
      ..chapterParagraphs['c0'] = ['网络正文 c0']
      ..chapterParagraphs['c1'] = ['网络正文 c1']
      ..failingChapterIds = {'c2'};
    final container = makeContainer();
    const args = ReaderArgs(bookId: '1', bookTitle: '在线书');

    final first = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
    );
    expect(first.displayedChapter!.id, 'c0');

    final controller = container.read(readerSessionProvider(args).notifier);
    await controller.nextChapter();
    final second = await openSession(
      container,
      args,
      ready: (state) => state.contentIndex == 1 && !state.loading,
    );
    expect(second.displayedChapter!.id, 'c1');

    // 切到 c2 失败：正文仍是 c1，index 退回 1，失败目标单独记在 failedIndex。
    await controller.nextChapter();
    final failed = await openSession(
      container,
      args,
      ready: (state) => state.error != null && !state.loading,
    );
    expect(failed.displayedChapter!.id, 'c1', reason: '不能把正在读的章清掉');
    expect(failed.content!.paragraphs, ['网络正文 c1']);
    expect(failed.index, 1, reason: 'index 要跟实际正文一致');
    expect(failed.failedIndex, 2, reason: '重试要能定位到失败的那一章');

    // 失败原因恢复后点重试：重试的是 failedIndex，而不是退回后的 index。
    transport.failingChapterIds = <String>{};
    await controller.retry();
    final recovered = await openSession(
      container,
      args,
      ready: (state) =>
          state.contentIndex == 2 && state.error == null && !state.loading,
    );
    expect(recovered.displayedChapter!.id, 'c2');
    expect(recovered.index, 2);
    expect(recovered.failedIndex, -1);
  });
}

/// 可编排的网络：目录/详情/正文分别返回，`failing` 时全部 500（模拟断网）。
class _OfflineTransport extends BackendTransport {
  _OfflineTransport() : super(port: 0);

  bool failing = false;
  List<String> directoryIds = const ['c0', 'c1', 'c2'];
  Duration directoryDelay = Duration.zero;

  /// 只让指定章节返回 500：用于验证「切章失败保留旧正文」。
  Set<String> failingChapterIds = <String>{};
  final Map<String, List<String>> chapterParagraphs = <String, List<String>>{};
  final List<String> directoryCalls = <String>[];
  final List<String> chapterCalls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    if (path.endsWith('/directory')) {
      directoryCalls.add(path);
      if (directoryDelay > Duration.zero) {
        await Future<void>.delayed(directoryDelay);
      }
    }
    if (failing) return _json(500, {'message': 'network down'});

    if (path.endsWith('/directory')) {
      return _json(200, {
        'code': 0,
        'data': {
          'item_data_list': [
            for (var i = 0; i < directoryIds.length; i++)
              {
                'item_id': directoryIds[i],
                'title': '网络第${i + 1}章',
                'volume_name': '',
              },
          ],
        },
      });
    }
    if (path.endsWith('/detail')) {
      return _json(200, {
        'code': 0,
        'data': {'book_id': '1', 'book_name': '网络书名'},
      });
    }
    if (path.contains('/chapters/')) {
      final id = Uri.decodeComponent(
        path.split('/chapters/')[1].split('/').first,
      );
      chapterCalls.add(id);
      if (failingChapterIds.contains(id)) {
        return _json(500, {'message': 'chapter down'});
      }
      final paragraphs = chapterParagraphs[id] ?? ['网络正文 $id'];
      return _json(200, {
        'code': 0,
        'data': {
          'content_decrypted': true,
          'title': '网络$id',
          'content': paragraphs.map((text) => '<p>$text</p>').join(),
        },
      });
    }
    return _json(200, {'code': 0, 'data': {}});
  }

  BackendResponse _json(int status, Map<String, dynamic> payload) =>
      BackendResponse(
        status,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        'application/json',
      );
}

/// 内存版自动缓存：记录写入，读命中与磁盘实现语义一致（这里不做 stale）。
class _RecordingChapterCache extends ReaderChapterCache {
  _RecordingChapterCache() : super(supportDirectory: _unsupportedDirectory);

  final Map<String, ChapterContent> memory = <String, ChapterContent>{};
  final List<String> puts = <String>[];

  @override
  Future<ReaderChapterHit?> get(String chapterId) async {
    final content = memory[chapterId];
    return content == null
        ? null
        : ReaderChapterHit(content: content, isStale: false);
  }

  @override
  Future<void> put(ChapterContent content) async {
    puts.add(content.id);
    memory[content.id] = content;
  }
}

Future<Directory> _unsupportedDirectory() async =>
    throw UnsupportedError('测试缓存不应访问磁盘');
