import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/widgets/webdav_config_sheet.dart';
import 'package:novel_playlet/features/sync/widgets/webdav_sync_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/memory_sync_log_store.dart';
import 'preview_harness.dart';

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('WebDAV：配置表单测试连接成功后才可保存并立即同步', (tester) async {
    final store = InMemoryWebDavConfigStore();
    final client = _FakeWebDavClient();
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(store),
        webDavClientProvider.overrideWithValue(client),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );

    await tester.ensureVisible(find.byKey(webDavConfigureKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(webDavConfigureKey));
    await tester.pumpAndSettle();

    expect(find.byKey(webDavUrlFieldKey), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(webDavSaveButtonKey)).onPressed,
      isNull,
      reason: '未测试连接前不能保存',
    );

    await tester.enterText(
      find.byKey(webDavUrlFieldKey),
      'https://dav.example.com/dav/',
    );
    await tester.enterText(find.byKey(webDavUserFieldKey), 'user@example.com');
    await tester.enterText(find.byKey(webDavPasswordFieldKey), 'app-password');
    await tester.tap(find.byKey(webDavTestButtonKey));
    await tester.pumpAndSettle();

    expect(client.tested, isNotNull);
    expect(find.text('连接成功'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(webDavSaveButtonKey)).onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(webDavSaveButtonKey));
    await tester.pumpAndSettle();

    expect(store.config?.baseUrl, 'https://dav.example.com/dav/');
    expect(store.config?.password, 'app-password');
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.textContaining('dav.example.com'), findsNothing);
    expect(find.byKey(webDavSyncNowKey), findsOneWidget);
    expect(find.textContaining('上次同步'), findsOneWidget);
    expect(client.files.keys.single.path, endsWith('/sync.json'));
  });
  testWidgets('WebDAV 弹层里有「同步记录」入口，能打开记录页', (tester) async {
    final store = InMemoryWebDavConfigStore();
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(store),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );

    await tester.ensureVisible(find.byKey(webDavConfigureKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(webDavConfigureKey));
    await tester.pumpAndSettle();

    expect(find.byKey(webDavLogKey), findsOneWidget);
    await tester.tap(find.byKey(webDavLogKey));
    await tester.pumpAndSettle();

    expect(find.text('同步记录'), findsWidgets);
    expect(find.text('还没有同步记录'), findsOneWidget);
  });
}

class _FakeWebDavClient implements WebDavClient {
  WebDavConfig? tested;
  final Map<Uri, String> files = {};

  @override
  Future<void> ensureDirectory(
    WebDavConfig config,
    String relativePath,
  ) async {}

  String _etagOf(String text) => '"${text.hashCode}"';

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
    tested = config;
    return const WebDavTestResult.success();
  }
}
