import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/sync_meta.dart';
import 'package:novel_playlet/features/sync/sync_snapshot.dart';
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
    // 区块标题叫「同步」，卡片里第一行只写「WebDAV」。
    expect(find.text('同步'), findsOneWidget);
    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.textContaining('dav.example.com'), findsNothing);
    expect(find.byKey(webDavSyncNowKey), findsOneWidget);
    expect(find.textContaining('上次同步'), findsOneWidget);
    expect(
      client.files.keys.any((uri) => uri.path.endsWith('/sync.json')),
      isTrue,
    );
    expect(
      client.files.keys.any((uri) => uri.path.endsWith('/settings.json')),
      isTrue,
      reason: '手动同步同时推书架与设置',
    );
  });
  testWidgets('设置页一级有「同步记录」入口，能打开记录页', (tester) async {
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

    await tester.ensureVisible(find.byKey(webDavLogKey));
    await tester.pumpAndSettle();
    // 两行导航入口都要有右侧箭头，明确「可点」。
    expect(
      find.descendant(
        of: find.byKey(webDavLogKey),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(webDavCloudDataKey),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(webDavLogKey));
    await tester.pumpAndSettle();

    expect(find.text('同步记录'), findsWidgets);
    expect(find.text('还没有同步记录'), findsOneWidget);
  });

  testWidgets('云端数据页：顶部元信息 + 最多 500 个提示 + 可读列表', (tester) async {
    final config = const WebDavConfig(
      baseUrl: 'https://dav.example.com/dav/',
      username: 'user',
      password: 'app-password',
    );
    final client = _FakeWebDavClient();
    final now = DateTime.now();
    final snapshot = SyncSnapshot(
      schemaVersion: SyncSnapshot.currentSchema,
      profile: syncProfile,
      deviceId: 'device-alpha',
      revision: 7,
      updatedAt: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
      data: {
        'items': [
          LibraryRecord(
            type: LibraryType.novel,
            sourceId: 'novel-1',
            title: '测试小说',
            progressRef: 'chapter-1',
            progressIndex: 11,
            lastReadAt: now
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
            shelfAt: now.millisecondsSinceEpoch,
          ).toJson(),
          LibraryRecord(
            type: LibraryType.playlet,
            sourceId: 'playlet-1',
            title: '测试短剧',
            progressIndex: 2,
            lastReadAt: now
                .subtract(const Duration(hours: 3))
                .millisecondsSinceEpoch,
          ).toJson(),
        ],
      },
    );
    client.files[config.resolve('$syncRemoteDir/sync.json')] = snapshot
        .encode();

    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(
          InMemoryWebDavConfigStore(config),
        ),
        webDavClientProvider.overrideWithValue(client),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );

    await tester.ensureVisible(find.byKey(webDavCloudDataKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(webDavCloudDataKey));
    await tester.pumpAndSettle();

    expect(find.text('云端数据'), findsWidgets);
    expect(find.text('device-alpha'), findsOneWidget);
    expect(find.text('第 7 版'), findsOneWidget);
    expect(find.text(syncProfile), findsOneWidget);
    expect(find.text('最多 500 个'), findsOneWidget);
    expect(find.text('测试小说'), findsOneWidget);
    expect(find.textContaining('第 12 章'), findsOneWidget);
    expect(find.text('测试短剧'), findsOneWidget);
    // 类型标签与「我的」页共用同一个单字样式。
    expect(find.text('书'), findsOneWidget);
    expect(find.text('剧'), findsOneWidget);
    expect(find.textContaining('第 3 集'), findsOneWidget);
    expect(find.textContaining('共 2 条'), findsOneWidget);
  });

  testWidgets('云端数据页：未配置和云端无文件分别提示', (tester) async {
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(
          InMemoryWebDavConfigStore(),
        ),
        webDavClientProvider.overrideWithValue(_FakeWebDavClient()),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );
    await tester.ensureVisible(find.byKey(webDavCloudDataKey));
    await tester.tap(find.byKey(webDavCloudDataKey));
    await tester.pumpAndSettle();
    expect(find.text('还没有配置 WebDAV'), findsOneWidget);
  });

  testWidgets('云端数据页：已配置但云端没有 sync.json 时提示为空', (tester) async {
    final config = const WebDavConfig(
      baseUrl: 'https://dav.example.com/dav/',
      username: 'user',
      password: 'app-password',
    );
    await pumpPreview(
      tester,
      const SettingsPage(),
      platform: TargetPlatform.iOS,
      extraOverrides: [
        webDavConfigStoreProvider.overrideWithValue(
          InMemoryWebDavConfigStore(config),
        ),
        webDavClientProvider.overrideWithValue(_FakeWebDavClient()),
        syncLogStoreProvider.overrideWithValue(MemorySyncLogStore()),
        syncLogRunsProvider.overrideWith((ref) async => const <SyncLogRun>[]),
      ],
    );
    await tester.ensureVisible(find.byKey(webDavCloudDataKey));
    await tester.tap(find.byKey(webDavCloudDataKey));
    await tester.pumpAndSettle();
    expect(find.text('云端还没有同步数据'), findsOneWidget);
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
