import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/diagnostics/diagnostic_log.dart';

DiagnosticEntry _entry(
  int at, {
  DiagnosticLevel level = DiagnosticLevel.error,
  DiagnosticSource source = DiagnosticSource.api,
  String message = 'GET /api/v1/a 失败：网络超时，请重试',
  String? detail,
  int count = 1,
}) {
  return DiagnosticEntry(
    at: at,
    level: level,
    source: source,
    message: message,
    detail: detail,
    count: count,
  );
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('app-log-test');
    DiagnosticLogStore.overridePath = '${dir.path}/app-log.json';
  });

  tearDown(() async {
    DiagnosticLogStore.overridePath = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('DiagnosticLogStore', () {
    test('追加按时间倒序，最多保留 200 条', () async {
      final store = DiagnosticLogStore();
      for (var i = 0; i < DiagnosticLogStore.maxEntries + 5; i++) {
        await store.append(_entry(1000 + i, message: '错误 $i'));
      }

      final entries = await store.read();
      expect(entries, hasLength(DiagnosticLogStore.maxEntries));
      expect(entries.first.message, '错误 ${DiagnosticLogStore.maxEntries + 4}');
      expect(entries.last.message, '错误 5', reason: '最旧的 5 条被丢掉');
    });

    test('同一错误在窗口内合并成一条并计数', () async {
      final store = DiagnosticLogStore();
      await store.append(_entry(1000));
      await store.append(_entry(1500));
      await store.append(_entry(2000));

      final entries = await store.read();
      expect(entries, hasLength(1));
      expect(entries.single.count, 3);
      expect(entries.single.at, 1000, reason: '保留首次发生时间');
    });

    test('超出合并窗口后单独记一条', () async {
      final store = DiagnosticLogStore();
      await store.append(_entry(1000));
      await store.append(
        _entry(1000 + DiagnosticLogStore.duplicateWindowMs + 1),
      );

      final entries = await store.read();
      expect(entries, hasLength(2));
      expect(entries.first.count, 1);
    });

    test('不同级别不合并', () async {
      final store = DiagnosticLogStore();
      await store.append(_entry(1000));
      await store.append(
        _entry(
          1200,
          level: DiagnosticLevel.unexpected,
          message: _entry(0).message,
        ),
      );

      expect(await store.read(), hasLength(2));
    });

    test('损坏文件按空日志处理，写入后覆盖', () async {
      final file = File(DiagnosticLogStore.overridePath!);
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');

      final store = DiagnosticLogStore();
      expect(await store.read(), isEmpty);
      await store.append(_entry(1));
      expect(await store.read(), hasLength(1));
    });

    test('清空后读到空列表', () async {
      final store = DiagnosticLogStore();
      await store.append(_entry(1));
      await store.clear();
      expect(await store.read(), isEmpty);
    });
  });

  group('DiagnosticEntry', () {
    test('JSON 往返保留级别 / 来源 / 计数 / 上下文', () {
      const entry = DiagnosticEntry(
        at: 10,
        level: DiagnosticLevel.unexpected,
        source: DiagnosticSource.api,
        message: 'GET /api/v1/recommend/homepage · 推荐返回的分类不匹配',
        detail: '期望 tab_type=8，实际=2',
        count: 3,
      );

      final decoded = DiagnosticEntry.tryFromJson(entry.toJson())!;
      expect(decoded.at, 10);
      expect(decoded.level, DiagnosticLevel.unexpected);
      expect(decoded.source, DiagnosticSource.api);
      expect(decoded.message, contains('分类不匹配'));
      expect(decoded.detail, '期望 tab_type=8，实际=2');
      expect(decoded.count, 3);
    });

    test('缺少 message 的脏行直接丢弃', () {
      expect(DiagnosticEntry.tryFromJson({'at': 1}), isNull);
      expect(DiagnosticEntry.tryFromJson('not a map'), isNull);
    });
  });
}
