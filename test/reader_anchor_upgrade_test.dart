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
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 段评锚点自愈：老 schema 缓存 / 升级前离线章节命中后，后台补取一次带
/// `<p idx>` 锚点的正文并回填当前章；气泡关闭时不发请求；离线补取结果在
/// 同一次会话里切走再回来仍要生效。
void main() {
  late Directory tempRoot;
  late _AnchorTransport transport;
  late _AnchorCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempRoot = await Directory.systemTemp.createTemp('reader_anchor_test_');
    transport = _AnchorTransport();
    cache = _AnchorCache();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响用例结果。
    }
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(transport)),
        offlinePathsProvider.overrideWithValue(
          OfflinePaths(rootDirectory: () async => tempRoot),
        ),
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

  test('老 schema 缓存命中后补取一次带锚点的正文并回填', () async {
    final container = makeContainer();
    const args = ReaderArgs(bookId: 'b1', bookTitle: '书');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content?.hasAnchors ?? false,
      reason: '等补取结果回填锚点',
    );
    expect(session.content!.paragraphs, ['第一段', '第二段']);
    expect(session.content!.hasAnchors, isTrue);
    expect(transport.chapterCalls, ['c0'], reason: '同一章只补取一次');
    expect(cache.puts, contains('c0'), reason: '补取结果写回自动缓存');
  });

  test('气泡关闭时不发补取请求', () async {
    SharedPreferences.setMockInitialValues({'reader_show_bubbles_v1': false});
    final container = makeContainer();
    // 等本地偏好恢复，避免冷启动默认值参与判定。
    await container.read(readerSettingsProvider.notifier).restoreFuture;
    const args = ReaderArgs(bookId: 'b1', bookTitle: '书');

    final session = await openSession(
      container,
      args,
      ready: (state) => state.content != null && !state.loading,
      reason: '老缓存正文先展示',
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(session.content!.hasAnchors, isFalse);
    expect(transport.chapterCalls, isEmpty, reason: '气泡关 = 0 次正文请求');
    expect(cache.puts, isEmpty);
  });

  test('离线老章节补取后，同会话切走再回来仍有锚点', () async {
    transport.directoryIds = const ['c0', 'c1'];
    final store = OfflineBookStore(
      paths: OfflinePaths(rootDirectory: () async => tempRoot),
    );
    await store.begin(
      OfflineBook(
        bookId: 'b1',
        title: '离线书',
        chapters: const [
          OfflineChapter(id: 'c0', title: '第1章', index: 0),
          OfflineChapter(id: 'c1', title: '第2章', index: 1),
        ],
        completed: 2,
      ),
    );
    for (final id in const ['c0', 'c1']) {
      await store.writeChapter(
        'b1',
        ChapterContent(id: id, title: id, paragraphs: ['离线正文 $id']),
      );
    }

    final container = makeContainer();
    const args = ReaderArgs(bookId: 'b1', bookTitle: '离线书');
    await openSession(
      container,
      args,
      ready: (state) => state.content?.hasAnchors ?? false,
      reason: '离线第一章补取后回填锚点',
    );
    // 等离线目录的后台刷新跑完，避免它和下面的切章互相覆盖状态。
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final controller = container.read(readerSessionProvider(args).notifier);
    await controller.nextChapter();
    await openSession(
      container,
      args,
      ready: (state) =>
          state.displayedChapter?.id == 'c1' &&
          (state.content?.hasAnchors ?? false),
      reason: '离线第二章补取',
    );
    await controller.previousChapter();
    final back = await openSession(
      container,
      args,
      ready: (state) =>
          state.displayedChapter?.id == 'c0' &&
          (state.content?.hasAnchors ?? false),
      reason: '切回第一章仍保留锚点',
    );
    expect(back.content!.paragraphs, ['第一段', '第二段']);
    expect(
      transport.chapterCalls.where((id) => id == 'c0').length,
      1,
      reason: '回退复用会话内的补取结果，不再请求',
    );
    expect(cache.puts, isEmpty, reason: '离线补取不写自动缓存');
  });
}

/// 正文都返回带 `<p idx>` 锚点的两段内容；目录可配置章节数。
class _AnchorTransport extends BackendTransport {
  _AnchorTransport() : super(port: 0);

  List<String> directoryIds = const ['c0'];
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
      return _json(200, {
        'code': 0,
        'data': {
          'item_data_list': [
            for (final id in directoryIds)
              {
                'item_id': id,
                'title': '第${id}章',
                'volume_name': '',
                'version': 'v1',
              },
          ],
        },
      });
    }
    if (path.endsWith('/detail')) {
      return _json(200, {
        'code': 0,
        'data': {'book_id': 'b1', 'book_name': '书'},
      });
    }
    if (path.contains('/chapters/')) {
      final id = Uri.decodeComponent(
        path.split('/chapters/')[1].split('/').first,
      );
      chapterCalls.add(id);
      return _json(200, {
        'code': 0,
        'data': {
          'content_decrypted': true,
          'content': '<p idx="0">第一段</p><p idx="1">第二段</p>',
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

/// 模拟「升级前写入的老缓存」：所有章节都命中一条没有锚点、标记
/// `anchorsOutdated` 的缓存。
class _AnchorCache extends ReaderChapterCache {
  _AnchorCache() : super(supportDirectory: _unsupportedDirectory);

  final List<String> puts = <String>[];

  @override
  Future<ReaderChapterHit?> get(String chapterId) async => ReaderChapterHit(
    content: ChapterContent(
      id: chapterId,
      title: '老缓存',
      paragraphs: const ['老缓存正文'],
    ),
    isStale: false,
    anchorsOutdated: true,
  );

  @override
  Future<void> put(ChapterContent content) async {
    puts.add(content.id);
  }
}

Future<Directory> _unsupportedDirectory() async =>
    throw UnsupportedError('测试缓存不应访问磁盘');
