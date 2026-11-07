import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/cache/offline_queue.dart';
import 'package:novel_playlet/features/cache/offline_task.dart';

/// 离线下载队列的纯单测：FIFO / 按 kind+id 去重 / remove / clear / maxLength。
///
/// 下载器的自动接续行为在 `offline_downloader_test.dart` 里用完整状态机验证；
/// 这里只测 Notifier 本身，不碰网络/磁盘。
void main() {
  late ProviderContainer container;
  late OfflineQueue queue;

  setUp(() {
    container = ProviderContainer();
    queue = container.read(offlineQueueProvider.notifier);
  });

  tearDown(() => container.dispose());

  OfflineQueueJob job(OfflineTaskKind kind, String id, {String title = ''}) =>
      OfflineQueueJob(
        kind: kind,
        id: id,
        title: title.isEmpty ? id : title,
        cover: 'cover-$id',
        items: const <Chapter>[],
      );

  /// `kind:id` 形式的当前队列快照，便于断言重复/多类型。
  List<String> keys() => [
    for (final task in container.read(offlineQueueProvider))
      '${task.kind.name}:${task.id}',
  ];

  test('FIFO：入队顺序即出队顺序，takeFirst 后发布剩余项', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    queue.enqueue(job(OfflineTaskKind.novel, 'b'));
    queue.enqueue(job(OfflineTaskKind.novel, 'c'));
    expect(keys(), ['novel:a', 'novel:b', 'novel:c']);

    expect(queue.takeFirst()?.id, 'a');
    expect(keys(), ['novel:b', 'novel:c']);
    expect(queue.takeFirst()?.id, 'b');
    expect(queue.takeFirst()?.id, 'c');
    expect(queue.takeFirst(), isNull);
    expect(container.read(offlineQueueProvider), isEmpty);
  });

  test('去重：kind+id 相同只保留一条，重复 enqueue 幂等', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    expect(keys(), ['novel:a']);

    // kind 不同、id 相同是两条（小说和短剧的 id 空间不同）。
    queue.enqueue(job(OfflineTaskKind.video, 'a'));
    expect(keys(), ['novel:a', 'video:a']);
  });

  test('contains 同时看 kind 与 id', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    expect(queue.contains(OfflineTaskKind.novel, 'a'), isTrue);
    expect(queue.contains(OfflineTaskKind.video, 'a'), isFalse);
    expect(queue.contains(OfflineTaskKind.novel, 'b'), isFalse);
  });

  test('remove：只移除指定 kind+id，返回是否命中并发布新列表', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    queue.enqueue(job(OfflineTaskKind.video, 'a'));
    queue.enqueue(job(OfflineTaskKind.novel, 'b'));

    expect(queue.remove(OfflineTaskKind.novel, 'a'), isTrue);
    expect(keys(), ['video:a', 'novel:b']);
    expect(queue.contains(OfflineTaskKind.novel, 'a'), isFalse);

    expect(queue.remove(OfflineTaskKind.novel, 'missing'), isFalse);
    expect(keys(), ['video:a', 'novel:b']);
  });

  test('clear：清空队列；对空队列调用是 no-op', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'a'));
    queue.enqueue(job(OfflineTaskKind.novel, 'b'));
    queue.clear();
    expect(container.read(offlineQueueProvider), isEmpty);

    queue.clear();
    expect(container.read(offlineQueueProvider), isEmpty);
  });

  test('maxLength=20：第 21 条抛 OfflineQueueFullException，满队列重复项不抛', () {
    expect(OfflineQueue.maxLength, 20);
    for (var i = 0; i < OfflineQueue.maxLength; i++) {
      queue.enqueue(job(OfflineTaskKind.novel, 'q$i'));
    }
    expect(container.read(offlineQueueProvider), hasLength(20));

    expect(
      () => queue.enqueue(job(OfflineTaskKind.novel, 'q-overflow')),
      throwsA(
        isA<OfflineQueueFullException>().having(
          (error) => error.maxLength,
          'maxLength',
          OfflineQueue.maxLength,
        ),
      ),
    );
    // 队列满时重复点击已在队列里的任务：幂等（去重先于满队列判断），不报错。
    expect(
      () => queue.enqueue(job(OfflineTaskKind.novel, 'q0')),
      returnsNormally,
    );
    expect(container.read(offlineQueueProvider), hasLength(20));
  });

  test('state 是 UI 快照：带 kind/id/title/cover，不含完整章节列表', () {
    queue.enqueue(job(OfflineTaskKind.novel, 'b1', title: '书A'));
    final snapshot = container.read(offlineQueueProvider).single;
    expect(snapshot.kind, OfflineTaskKind.novel);
    expect(snapshot.id, 'b1');
    expect(snapshot.title, '书A');
    expect(snapshot.cover, 'cover-b1');
  });
}
