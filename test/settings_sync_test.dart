import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_font_weight.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:novel_playlet/features/sync/settings_sections.dart';
import 'package:novel_playlet/features/sync/settings_sync_coordinator.dart';
import 'package:novel_playlet/features/sync/settings_sync_meta.dart';
import 'package:novel_playlet/features/sync/settings_sync_service.dart';
import 'package:novel_playlet/features/sync/settings_sync_snapshot.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = WebDavConfig(
  baseUrl: 'https://dav.example.com/dav/',
  username: 'user',
  password: 'password',
);

final _settingsUri = _config.resolve('novel-playlet/release/settings.json');

class _FakeSettingsClient implements WebDavClient {
  final Map<Uri, String> files = {};
  int reads = 0;
  int writes = 0;
  void Function(Uri uri)? beforeNextWrite;

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
    reads++;
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
    writes++;
    beforeNextWrite?.call(uri);
    beforeNextWrite = null;
    final current = files[uri];
    if (ifMatch != null && (current == null || _etagOf(current) != ifMatch)) {
      throw WebDavPreconditionFailed('云端文件已被另一台设备改过');
    }
    files[uri] = text;
    return _etagOf(text);
  }

  @override
  Future<WebDavTestResult> testConnection(WebDavConfig config) async =>
      const WebDavTestResult.success();
}

class _FakeSection implements SettingsSection {
  _FakeSection(this.id, this.value);

  @override
  final String id;

  Object? value;
  Object? applied;

  @override
  Object? capture() => value;

  @override
  Future<void> applyRemote(Object? data) async {
    applied = data;
    value = data;
  }
}

void main() {
  late _FakeSettingsClient client;
  late SettingsSyncMetaStore metaStore;
  late _FakeSection section;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    client = _FakeSettingsClient();
    metaStore = SettingsSyncMetaStore();
    section = _FakeSection('group', {'a': 1});
  });

  SettingsSyncService service({
    bool immersive = false,
    required Future<void> Function(Map<String, Object?> settings, int updatedAt)
    onApply,
    required Future<void> Function(int updatedAt) onTimestamp,
  }) {
    return SettingsSyncService(
      client: client,
      metaStore: metaStore,
      sections: [section],
      logStore: SyncLogStore(),
      profile: 'release',
      isImmersive: () => immersive,
      applyRemote: onApply,
      onSyncedTimestamp: onTimestamp,
    );
  }

  void putRemote({required int updatedAt, required Object? value}) {
    client.files[_settingsUri] = SettingsSnapshot(
      deviceId: 'remote-device',
      updatedAt: updatedAt,
      settings: {'group': value},
    ).encode();
  }

  test('云端没有设置时把本地推上去，并写一条 scope=settings 的记录', () async {
    int? syncedAt;
    final sync = service(
      onApply: (_, _) async {},
      onTimestamp: (at) async => syncedAt = at,
    );

    final result = await sync.sync(_config, localUpdatedAt: 1000);

    expect(result.action, SettingsSyncAction.uploaded);
    expect(syncedAt, isNotNull);
    final parsed = SettingsSnapshot.parse(client.files[_settingsUri]!);
    expect(parsed, isA<SettingsSnapshotOk>());
    expect((parsed as SettingsSnapshotOk).snapshot.settings['group'], {'a': 1});

    final run = (await SyncLogStore().read()).single;
    expect(run.scope, SyncScope.settings);
    expect(run.outcome, SyncOutcome.success);
    expect(run.uploaded, isTrue);
  });

  test('云端更新时应用到本机，且不覆盖云端', () async {
    putRemote(updatedAt: 5000, value: {'a': 2});
    int? appliedAt;
    final sync = service(
      onApply: (settings, at) async {
        appliedAt = at;
        await section.applyRemote(settings['group']);
      },
      onTimestamp: (_) async {},
    );

    final result = await sync.sync(_config, localUpdatedAt: 1000);

    expect(result.action, SettingsSyncAction.pulled);
    expect(section.applied, {'a': 2});
    expect(appliedAt, 5000);
    final meta = await metaStore.read();
    expect(meta.lastRemoteUpdatedAt, 5000);
    expect(client.writes, 0);
    expect((await SyncLogStore().read()).single.pulledTotal, 1);
  });

  test('本地改动比云端新时以本地为准', () async {
    putRemote(updatedAt: 5000, value: {'a': 2});
    final sync = service(onApply: (_, _) async {}, onTimestamp: (_) async {});

    final result = await sync.sync(_config, localUpdatedAt: 6000);

    expect(result.action, SettingsSyncAction.uploaded);
    final parsed = SettingsSnapshot.parse(client.files[_settingsUri]!);
    final snapshot = (parsed as SettingsSnapshotOk).snapshot;
    expect(snapshot.settings['group'], {'a': 1});
    expect(snapshot.updatedAt, greaterThan(6000));
  });

  test('云端未知版本时停止同步，不降级覆盖', () async {
    client.files[_settingsUri] =
        '{"v":2,"deviceId":"x","updatedAt":1,"settings":{"group":{"a":9}}}';
    final sync = service(onApply: (_, _) async {}, onTimestamp: (_) async {});

    await expectLater(
      sync.sync(_config, localUpdatedAt: 6000),
      throwsA(isA<WebDavException>()),
    );

    expect(client.writes, 0);
    expect(client.files[_settingsUri], contains('"v":2'));
    final run = (await SyncLogStore().read()).single;
    expect(run.outcome, SyncOutcome.failed);
    expect(run.error, contains('高于当前 App'));
  });

  test('沉浸页挡住 apply：只推进 etag，下次再应用', () async {
    putRemote(updatedAt: 5000, value: {'a': 2});
    var immersive = true;
    int? appliedAt;
    final sync = SettingsSyncService(
      client: client,
      metaStore: metaStore,
      sections: [section],
      logStore: SyncLogStore(),
      profile: 'release',
      isImmersive: () => immersive,
      applyRemote: (settings, at) async {
        appliedAt = at;
        await section.applyRemote(settings['group']);
      },
      onSyncedTimestamp: (_) async {},
    );

    final first = await sync.sync(_config, localUpdatedAt: 1000);
    expect(first.action, SettingsSyncAction.deferred);
    expect(section.applied, isNull);
    expect((await metaStore.read()).lastRemoteUpdatedAt, 0);

    immersive = false;
    final second = await sync.sync(_config, localUpdatedAt: 1000);
    expect(second.action, SettingsSyncAction.pulled);
    expect(appliedAt, 5000);
    expect(section.value, {'a': 2});
  });

  test('412 后重读云端并按 LWW 重新判胜', () async {
    putRemote(updatedAt: 5000, value: {'a': 2});
    final sync = service(
      onApply: (settings, at) async {
        await section.applyRemote(settings['group']);
      },
      onTimestamp: (_) async {},
    );

    // 第一次 PUT 前另一台设备抢先写入更新的设置。
    client.beforeNextWrite = (_) {
      putRemote(updatedAt: 9000, value: {'a': 9});
    };

    final result = await sync.sync(_config, localUpdatedAt: 6000);

    expect(client.writes, 1, reason: '第一次 PUT 412，重读后远端更新，改为 apply');
    expect(result.action, SettingsSyncAction.pulled);
    expect(section.value, {'a': 9});
  });

  test('指纹与键顺序无关，未知/损坏文件严格拒绝', () {
    expect(hashSettings({'a': 1, 'b': 2}), hashSettings({'b': 2, 'a': 1}));
    expect(
      SettingsSnapshot.parse('{"v":2}'),
      isA<SettingsSnapshotUnsupported>(),
    );
    expect(
      SettingsSnapshot.parse(
        '{"v":1,"deviceId":"","updatedAt":1,"settings":{}}',
      ),
      isA<SettingsSnapshotInvalid>(),
    );
    expect(SettingsSnapshot.parse('not json'), isA<SettingsSnapshotInvalid>());
  });

  test('SettingsSection 对脏值做 clamp / 白名单回落', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sections = container.read(settingsSectionsProvider);
    final readerSection = sections.firstWhere((s) => s.id == 'reader');

    await readerSection.applyRemote({
      'fontSize': 99,
      'lineHeight': 0,
      'fontWeight': 999,
      'followGlobalFontWeight': 'yes',
      'paper': 'bogus',
      'dayPaper': 'night',
      'showBubbles': 'no',
      'dialogueHighlightColor': -1,
      'dialogueHighlightStyle': 'bogus',
    });

    final reader = container.read(readerSettingsProvider);
    expect(reader.fontSize, ReaderSettingsController.maxFontSize);
    expect(reader.lineHeight, ReaderSettingsController.minLineHeight);
    expect(reader.fontWeight.value, 800);
    expect(reader.followGlobalFontWeight, isTrue);
    expect(reader.paper, ReaderPaper.parchment);
    expect(reader.dayPaper, ReaderPaper.parchment);
    expect(reader.showBubbles, isTrue);
    expect(
      reader.dialogueHighlightColor,
      ReaderSettings.defaultDialogueHighlightColor,
    );

    final themeSection = sections.firstWhere((s) => s.id == 'theme');
    await themeSection.applyRemote({
      'seed': 0xFF123456,
      'mode': 'dark',
      'variant': 'vibrant',
    });
    expect(container.read(themeSeedProvider).toARGB32(), 0xFF123456);
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(container.read(themeVariantProvider), AppThemeVariant.vibrant);

    final fontSection = sections.firstWhere((s) => s.id == 'fontWeight');
    await fontSection.applyRemote(999);
    expect(container.read(appFontWeightProvider).value, 500);
  });

  test('coordinator 手动同步会把本地主题推到 settings.json', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer(
      overrides: [
        webDavConfigProvider.overrideWith((ref) async => _config),
        webDavClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);

    final coordinator = container.read(settingsSyncStatusProvider.notifier);
    container.read(themeSeedProvider.notifier).setSeed(const Color(0xFF123456));
    await coordinator.syncNow(trigger: SyncTrigger.manual);

    final parsed = SettingsSnapshot.parse(client.files.values.single);
    final settings =
        (parsed as SettingsSnapshotOk).snapshot.settings['theme'] as Map;
    expect(settings['seed'], 0xFF123456);
    // 没主动改过算法时也要写进快照：否则另一台设备读到的 default 可能是
    // 未来改过的默认档，而不是这台机器实际在用的档位。
    expect(settings['variant'], AppThemeVariant.standard.name);
    expect(
      container.read(settingsSyncStatusProvider).phase,
      SettingsSyncPhase.success,
    );
  });
}
