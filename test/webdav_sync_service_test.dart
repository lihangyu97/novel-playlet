import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';
import 'package:novel_playlet/features/sync/sync_meta.dart';
import 'package:novel_playlet/features/sync/sync_service.dart';
import 'package:novel_playlet/features/sync/sync_snapshot.dart';
import 'package:novel_playlet/features/sync/webdav_client.dart';
import 'package:novel_playlet/features/sync/webdav_config.dart';
import 'package:novel_playlet/data/models/novel_item.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebDavClient client;
  late ReadingStore store;

  setUp(() {
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
    expect(snapshot.schemaVersion, SyncSnapshot.currentSchema);
    expect(snapshot.data['items'], hasLength(1));
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
    final newer = DateTime.now().millisecondsSinceEpoch + 100000;
    client.files[file] = SyncSnapshot(
      schemaVersion: SyncSnapshot.currentSchema,
      profile: snapshot.profile,
      deviceId: snapshot.deviceId,
      revision: snapshot.revision,
      updatedAt: snapshot.updatedAt,
      data: {
        'items': [
          {
            'type': 'novel',
            'id': 'a',
            'title': 'A',
            'lastReadAt': newer,
            'chapterId': 'remote',
            'chapterIndex': 9,
          },
        ],
      },
    ).encode();

    final result = await service.sync(config);
    expect(result.pulled, isTrue);
    expect((await store.progress('a'))?.chapterId, 'remote');
    final uploaded = SyncSnapshot.tryParse(client.files[file]!)!;
    final first = (uploaded.data['items'] as List).single as Map;
    expect(first['chapterId'], 'remote');
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
  test('ETag 与本地指纹都没变时整轮跳过，不再读写远端', () async {
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config);
    final readsAfterFirst = client.reads;
    final writesAfterFirst = client.writes;

    final second = await service.sync(config);
    expect(second.skipped, isTrue);
    expect(client.reads, readsAfterFirst, reason: '命中条件请求就不该再 GET');
    expect(client.writes, writesAfterFirst, reason: '没变化就不该再 PUT');
  });

  test('PUT 被 412 拒绝时重读重合并，第二次写入成功', () async {
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config);
    final file = client.files.keys.single;

    // 本地又加了本书，云端同时被另一台设备写入了另一本。
    await store.addToShelf(const NovelItem(id: 'local', title: '本地新加'));
    final remoteSnapshot = SyncSnapshot.tryParse(client.files[file]!)!;
    final remoteItems = [
      ...(remoteSnapshot.data['items'] as List),
      {'type': 'novel', 'id': 'remote', 'title': '另一台设备', 'shelfAt': 1000},
    ];
    client.beforeNextWrite = (uri) {
      client.files[uri] = SyncSnapshot(
        schemaVersion: SyncSnapshot.currentSchema,
        profile: remoteSnapshot.profile,
        deviceId: 'other-device',
        revision: remoteSnapshot.revision + 1,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        data: {'items': remoteItems},
      ).encode();
    };

    final result = await service.sync(config);
    expect(result.uploaded, isTrue);
    final finalSnapshot = SyncSnapshot.tryParse(client.files[file]!)!;
    final ids = (finalSnapshot.data['items'] as List)
        .map((item) => (item as Map)['id'])
        .toList();
    expect(ids, containsAll(['a', 'local', 'remote']), reason: '两边改动都要收敛');
  });

  test('同步会写一条日志：结果、revision 与上传明细', () async {
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config, trigger: SyncTrigger.lifecycle);

    final runs = await SyncLogStore().read();
    expect(runs, hasLength(1));
    final run = runs.single;
    expect(run.outcome, SyncOutcome.success);
    expect(run.trigger, SyncTrigger.lifecycle);
    expect(run.uploaded, isTrue);
    expect(run.revBefore, 0);
    expect(run.revAfter, 1);
    expect(run.pushedTotal, 1);
    expect(run.pushed.single.key, 'novel/a');
    expect(run.error, isNull);
  });

  test('条件请求跳过的同步记为 skipped', () async {
    await store.addToShelf(const NovelItem(id: 'a', title: 'A'));
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );
    await service.sync(config);
    await service.sync(config);

    final runs = await SyncLogStore().read();
    expect(runs, hasLength(2));
    expect(runs.first.outcome, SyncOutcome.skipped);
    expect(runs.first.revAfter, runs.first.revBefore);
  });

  test('同步失败时日志记下失败阶段与错误文案', () async {
    client.files[config.resolve('novel-playlet/release/sync.json')] = '{broken';
    final service = WebDavSyncService(
      store: store,
      client: client,
      metaStore: SyncMetaStore(),
      profile: 'release',
    );

    await expectLater(service.sync(config), throwsA(isA<WebDavException>()));
    final runs = await SyncLogStore().read();
    expect(runs.single.outcome, SyncOutcome.failed);
    expect(runs.single.phase, 'parse');
    expect(runs.single.error, contains('格式不正确'));
  });
}

class _FakeWebDavClient implements WebDavClient {
  final Map<Uri, String> files = {};

  @override
  Future<void> ensureDirectory(
    WebDavConfig config,
    String relativePath,
  ) async {}

  /// 用内容哈希当 ETag：测试里直接改 `files[uri]` 也会让 ETag 变化，
  /// 和真实服务器"内容变了 ETag 就变"一致。
  String _etagOf(String text) => '"${text.hashCode}"';

  int reads = 0;
  int writes = 0;

  /// 在下一次 PUT 真正执行前插一刀，用来模拟"另一台设备抢先写入"。
  void Function(Uri uri)? beforeNextWrite;

  @override
  Future<String?> readText(
    WebDavConfig config,
    Uri uri, {
    void Function(String? etag)? onEtag,
  }) async {
    reads++;
    final text = files[uri];
    onEtag?.call(text == null ? null : _etagOf(text));
    return text;
  }

  @override
  Future<WebDavFileMeta?> stat(WebDavConfig config, Uri uri) async {
    final text = files[uri];
    return text == null ? null : WebDavFileMeta(etag: _etagOf(text));
  }

  @override
  Future<void> writeText(
    WebDavConfig config,
    Uri uri,
    String text, {
    String? ifMatch,
  }) async {
    final hook = beforeNextWrite;
    if (hook != null) {
      beforeNextWrite = null;
      hook(uri);
    }
    writes++;
    final current = files[uri];
    if (ifMatch != null && (current == null || _etagOf(current) != ifMatch)) {
      throw WebDavPreconditionFailed('conflict', statusCode: 412);
    }
    files[uri] = text;
  }

  @override
  Future<WebDavTestResult> testConnection(WebDavConfig config) async =>
      const WebDavTestResult.success();
}
