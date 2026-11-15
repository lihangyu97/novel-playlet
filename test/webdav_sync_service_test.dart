import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/features/sync/sync_meta.dart';
import 'package:novel_playlet/features/sync/sync_service.dart';
import 'package:novel_playlet/features/sync/sync_snapshot.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebDavClient client;
  late ReadingStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = _FakeWebDavClient();
    store = ReadingStore();
  });

  const config = WebDavConfig(
    baseUrl: 'https://dav.example.com/dav/',
    username: 'user',
    password: 'password',
  );

  test('首次同步上传 release 目录下的 JSON 快照', () async {
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    final result = await service.sync(config);

    expect(result.uploaded, isTrue);
    final file = client.files.keys.single;
    expect(file.path, '/dav/novel-playlet/release/sync.json');
    final snapshot = SyncSnapshot.tryParse(client.files[file]!);
    expect(snapshot, isNotNull);
    expect(snapshot!.profile, 'release');
    expect(snapshot.data['novelShelf'], hasLength(1));
  });

  test('beta 渠道写到独立目录，不碰 release 数据', () async {
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'beta',
    );
    await service.sync(config);
    expect(client.files.keys.single.path, '/dav/novel-playlet/beta/sync.json');
  });

  test('云端较新的进度会拉回本地，并重新上传合并结果', () async {
    await store.saveProgress(
      bookId: 'a',
      bookTitle: 'A',
      cover: '',
      chapterId: 'local',
      chapterIndex: 1,
    );
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config);

    final file = client.files.keys.single;
    final snapshot = SyncSnapshot.tryParse(client.files[file]!)!;
    final data = Map<String, dynamic>.from(snapshot.data);
    data['novelProgress'] = {
      'a': {
        'bookId': 'a',
        'bookTitle': 'A',
        'cover': '',
        'chapterId': 'remote',
        'chapterIndex': 9,
        'blockIndex': 0,
        'updatedAt': DateTime.now().millisecondsSinceEpoch + 100000,
      },
    };
    client.files[file] = SyncSnapshot(
      schemaVersion: snapshot.schemaVersion,
      profile: snapshot.profile,
      deviceId: snapshot.deviceId,
      revision: snapshot.revision,
      updatedAt: snapshot.updatedAt,
      data: data,
    ).encode();

    final result = await service.sync(config);
    expect(result.pulled, isTrue);
    expect((await store.progress('a'))?.chapterId, 'remote');
    final uploaded = SyncSnapshot.tryParse(client.files[file]!)!;
    expect((uploaded.data['novelProgress'] as Map)['a']['chapterId'], 'remote');
  });

  test('云端 JSON 损坏时停止同步，不覆盖远端文件', () async {
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config);
    final file = client.files.keys.single;
    client.files[file] = '{broken';

    await expectLater(service.sync(config), throwsA(isA<WebDavException>()));
    expect(client.files[file], '{broken');
  });
}

class _FakeWebDavClient implements WebDavClient {
  final Map<Uri, String> files = {};

  @override
  Future<void> ensureDirectory(
    WebDavConfig config,
    String relativePath,
  ) async {}

  @override
  Future<String?> readText(WebDavConfig config, Uri uri) async => files[uri];

  @override
  Future<void> writeText(WebDavConfig config, Uri uri, String text) async {
    files[uri] = text;
  }

  @override
  Future<WebDavTestResult> testConnection(WebDavConfig config) async =>
      const WebDavTestResult.success();
}
