import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/mine/widgets/mine_all_sheet.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/sync_meta.dart';
import 'package:novel_playlet/features/sync/sync_snapshot.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';

import '../support/memory_sync_log_store.dart';
import 'preview_harness.dart';

/// 我的页删除后立刻推一次 WebDAV：验证「删除不是只落本地」。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  testWidgets('移出收藏后立即上传墓碑，云端不再有这一条', (tester) async {
    final store = ReadingStore();
    for (var i = 1; i <= 8; i++) {
      await store.addToShelf(NovelItem(id: 'b$i', title: '书$i'));
    }

    const config = WebDavConfig(
      baseUrl: 'https://dav.example.com/dav/',
      username: 'user',
      password: 'app-password',
    );
    final client = _FakeWebDavClient();
    await pumpPreview(
      tester,
      const MinePage(),
      store: store,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(
          InMemoryWebDavConfigStore(config),
        ),
        webDavClientProvider.overrideWithValue(client),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
      ],
    );

    await tester.tap(find.byKey(MinePage.collectionAllKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.drag(
      find.descendant(
        of: find.byKey(mineAllSheetKey),
        matching: find.text('书1'),
      ),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('移出收藏'),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final syncUri = config.resolve('$syncRemoteDir/sync.json');
    for (var i = 0; i < 40 && !client.files.containsKey(syncUri); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(client.files.containsKey(syncUri), isTrue, reason: '删除后应自动同步');
    final snapshot = SyncSnapshot.tryParse(client.files[syncUri]!)!;
    final item = (snapshot.data['items'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((record) => record['id'] == 'b1');
    expect(item['shelfRemovedAt'], greaterThan(0), reason: '云端要收到删除墓碑');
    expect(item.containsKey('title'), isFalse, reason: '墓碑瘦身，不传书名封面');
  });

  testWidgets('删除历史后立即上传裁剪墓碑，收藏保留', (tester) async {
    final store = ReadingStore();
    await store.addToShelf(const NovelItem(id: 'b1', title: '书1'));
    for (var i = 1; i <= 3; i++) {
      await store.saveProgress(
        bookId: 'b$i',
        bookTitle: '书$i',
        cover: '',
        chapterId: 'c$i',
        chapterIndex: i,
      );
    }

    const config = WebDavConfig(
      baseUrl: 'https://dav.example.com/dav/',
      username: 'user',
      password: 'app-password',
    );
    final client = _FakeWebDavClient();
    await pumpPreview(
      tester,
      const MinePage(),
      store: store,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(
          InMemoryWebDavConfigStore(config),
        ),
        webDavClientProvider.overrideWithValue(client),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
      ],
    );

    await tester.tap(find.byKey(MinePage.historyAllKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    await tester.drag(
      find.descendant(
        of: find.byKey(mineAllSheetKey),
        matching: find.text('书1'),
      ),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final syncUri = config.resolve('$syncRemoteDir/sync.json');
    for (var i = 0; i < 40 && !client.files.containsKey(syncUri); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(client.files.containsKey(syncUri), isTrue, reason: '删除历史后应自动同步');
    final snapshot = SyncSnapshot.tryParse(client.files[syncUri]!)!;
    final item = (snapshot.data['items'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((record) => record['id'] == 'b1');
    expect(item['progressPrunedAt'], greaterThan(0), reason: '云端要收到进度裁剪墓碑');
    expect(item['shelfAt'], greaterThan(0), reason: '收藏状态保留');
    expect(item['title'], '书1', reason: '还在收藏里，快照不能清');
    expect(item.containsKey('lastReadAt'), isFalse);
    expect(await store.isOnShelf('b1'), isTrue);
    expect(await store.historyCount(), 2);
  });
}

/// 内存 WebDAV：接口形状与 `webdav_client_test` 里的假实现一致。
class _FakeWebDavClient implements WebDavClient {
  final Map<Uri, String> files = {};

  String _etagOf(String text) => '"${text.hashCode}"';

  @override
  Future<void> ensureDirectory(
    WebDavConfig config,
    String relativePath,
  ) async {}

  @override
  Future<WebDavRead> readFile(
    WebDavConfig config,
    Uri uri, {
    String? ifNoneMatch,
  }) async {
    final text = files[uri];
    if (text == null) return const WebDavRead.absent();
    final etag = _etagOf(text);
    if (ifNoneMatch != null && ifNoneMatch == etag) {
      return WebDavRead.notModified(etag);
    }
    return WebDavRead.content(text, etag);
  }

  @override
  Future<WebDavFileMeta?> stat(WebDavConfig config, Uri uri) async {
    final text = files[uri];
    return text == null ? null : WebDavFileMeta(etag: _etagOf(text));
  }

  @override
  Future<String?> writeText(
    WebDavConfig config,
    Uri uri,
    String text, {
    String? ifMatch,
  }) async {
    final current = files[uri];
    if (ifMatch != null && (current == null || _etagOf(current) != ifMatch)) {
      throw WebDavPreconditionFailed('conflict', statusCode: 412);
    }
    files[uri] = text;
    return _etagOf(text);
  }

  @override
  Future<WebDavTestResult> testConnection(WebDavConfig config) async {
    return const WebDavTestResult.success();
  }
}
