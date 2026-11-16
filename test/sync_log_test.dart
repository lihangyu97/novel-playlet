import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/library_records.dart';
import 'package:novel_playlet/features/sync/sync_log.dart';

Map<String, dynamic> dataOf(List<LibraryRecord> records) => {
  'items': [for (final record in records) record.toJson()],
};

void main() {
  group('diffLibraryData', () {
    test('新增记录会拆成书名 / 进度 / 收藏三类变化', () {
      const record = LibraryRecord(
        type: LibraryType.novel,
        sourceId: 'a',
        title: '剑来',
        lastReadAt: 100,
        progressRef: 'c3',
        progressIndex: 2,
        progressSub: 4,
        shelfAt: 100,
      );

      final changes = diffLibraryData(const {
        'items': <dynamic>[],
      }, dataOf([record]));
      expect(changes, hasLength(1));
      final fields = changes.single.fields.map((field) => field.field);
      expect(fields, containsAll(['title', 'progress', 'shelf']));
      final progress = changes.single.fields.firstWhere(
        (field) => field.field == 'progress',
      );
      expect(progress.after, '第 3 章 · 第 5 段');
    });

    test('移出收藏渲染成「加入 → 移出」', () {
      const before = LibraryRecord(
        type: LibraryType.novel,
        sourceId: 'a',
        title: '剑来',
        shelfAt: 100,
      );
      final after = before.copyWith(shelfRemovedAt: 200);

      final fields = diffLibraryData(
        dataOf([before]),
        dataOf([after]),
      ).single.fields;
      final shelf = fields.firstWhere((field) => field.field == 'shelf');
      expect([shelf.before, shelf.after], ['加入', '移出']);
    });

    test('短剧进度按集渲染，未变化的记录不记', () {
      const before = LibraryRecord(
        type: LibraryType.playlet,
        sourceId: 'p1',
        title: '短剧',
        lastReadAt: 100,
        progressIndex: 2,
      );
      final after = before.copyWith(lastReadAt: 200, progressIndex: 5);

      final changes = diffLibraryData(
        dataOf([
          before,
          const LibraryRecord(type: LibraryType.novel, sourceId: 'same'),
        ]),
        dataOf([
          after,
          const LibraryRecord(type: LibraryType.novel, sourceId: 'same'),
        ]),
      );
      expect(changes, hasLength(1));
      expect(changes.single.type, LibraryType.playlet);
      expect(changes.single.fields.single.after, '第 6 集');
    });

    test('书名变化走快照字段，封面不贴 URL', () {
      const before = LibraryRecord(
        type: LibraryType.novel,
        sourceId: 'a',
        title: '旧名',
        cover: 'https://example.com/a.jpg',
      );
      final after = before.copyWith(
        title: '新名',
        cover: 'https://example.com/b.jpg',
      );

      final fields = diffLibraryData(
        dataOf([before]),
        dataOf([after]),
      ).single.fields;
      expect(
        fields.map((field) => field.field),
        containsAll(['title', 'cover']),
      );
      expect(
        fields.every(
          (field) =>
              !field.before.contains('http') && !field.after.contains('http'),
        ),
        isTrue,
      );
    });
  });

  group('SyncLogStore', () {
    test('追加按时间倒序，最多保留 50 条', () async {
      final store = SyncLogStore();
      for (var i = 0; i < 55; i++) {
        await store.append(
          SyncLogRun(
            at: 1000 + i,
            durationMs: i,
            outcome: SyncOutcome.success,
            trigger: SyncTrigger.manual,
          ),
        );
      }

      final runs = await store.read();
      expect(runs, hasLength(SyncLogStore.maxRuns));
      expect(runs.first.at, 1054, reason: '最新的在最前');
      expect(runs.last.at, 1005, reason: '最旧的 5 条被丢掉');
    });

    test('损坏文件按空日志处理，写入后覆盖', () async {
      final file = File(SyncLogStore.overridePath!);
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');

      final store = SyncLogStore();
      expect(await store.read(), isEmpty);
      await store.append(
        const SyncLogRun(
          at: 1,
          durationMs: 2,
          outcome: SyncOutcome.skipped,
          trigger: SyncTrigger.lifecycle,
        ),
      );
      expect(await store.read(), hasLength(1));
    });

    test('清空后读到空列表', () async {
      final store = SyncLogStore();
      await store.append(
        const SyncLogRun(
          at: 1,
          durationMs: 2,
          outcome: SyncOutcome.success,
          trigger: SyncTrigger.manual,
        ),
      );
      await store.clear();
      expect(await store.read(), isEmpty);
    });

    test('JSON 往返保留失败阶段与明细', () async {
      const run = SyncLogRun(
        at: 10,
        durationMs: 20,
        outcome: SyncOutcome.failed,
        trigger: SyncTrigger.config,
        phase: 'put',
        revBefore: 3,
        revAfter: 3,
        error: '上传同步文件失败：网盘空间或流量不足',
        pushed: [
          SyncLogChange(
            key: 'novel/a',
            type: LibraryType.novel,
            title: '剑来',
            fields: [
              SyncLogField(field: 'progress', before: '第 1 章', after: '第 2 章'),
            ],
          ),
        ],
        pushedTotal: 1,
      );
      final decoded = SyncLogRun.tryFromJson(run.toJson())!;
      expect(decoded.outcome, SyncOutcome.failed);
      expect(decoded.phase, 'put');
      expect(decoded.error, contains('流量不足'));
      expect(decoded.pushed.single.fields.single.after, '第 2 章');
    });
  });
}
