import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/library_records.dart';
import '../../core/storage/offline/offline_paths.dart';
import '../../data/models/json_utils.dart';

/// 一次同步是怎么被触发的。
enum SyncTrigger {
  manual('manual'),
  lifecycle('lifecycle'),
  config('config');

  const SyncTrigger(this.wire);

  final String wire;

  static SyncTrigger parse(Object? value) {
    final wire = asString(value);
    for (final trigger in SyncTrigger.values) {
      if (trigger.wire == wire) return trigger;
    }
    return SyncTrigger.manual;
  }
}

enum SyncOutcome {
  success('success'),
  failed('failed'),
  skipped('skipped');

  const SyncOutcome(this.wire);

  final String wire;

  static SyncOutcome parse(Object? value) {
    final wire = asString(value);
    for (final outcome in SyncOutcome.values) {
      if (outcome.wire == wire) return outcome;
    }
    return SyncOutcome.failed;
  }
}

/// 一个字段的变化。`before` / `after` 存渲染好的文案，页面不用再懂小说/短剧。
class SyncLogField {
  const SyncLogField({
    required this.field,
    required this.before,
    required this.after,
  });

  final String field;
  final String before;
  final String after;

  Map<String, dynamic> toJson() => {'f': field, 'b': before, 'a': after};

  static SyncLogField? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    return SyncLogField(
      field: asString(json['f']),
      before: asString(json['b']),
      after: asString(json['a']),
    );
  }
}

/// 一条内容在这一次同步里变了什么。
class SyncLogChange {
  const SyncLogChange({
    required this.key,
    required this.type,
    required this.title,
    required this.fields,
  });

  final String key;
  final LibraryType type;
  final String title;
  final List<SyncLogField> fields;

  Map<String, dynamic> toJson() => {
    'k': key,
    'ty': type.wire,
    if (title.isNotEmpty) 't': title,
    'f': [for (final field in fields) field.toJson()],
  };

  static SyncLogChange? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final type = LibraryType.tryParse(json['ty']) ?? LibraryType.novel;
    return SyncLogChange(
      key: asString(json['k']),
      type: type,
      title: asString(json['t']),
      fields: [
        for (final field in asList(json['f'])) ?SyncLogField.tryFromJson(field),
      ],
    );
  }
}

/// 一次同步的记录（列表里的那一行）。
class SyncLogRun {
  const SyncLogRun({
    required this.at,
    required this.durationMs,
    required this.outcome,
    required this.trigger,
    this.phase,
    this.revBefore = 0,
    this.revAfter = 0,
    this.uploaded = false,
    this.remoteDeviceId = '',
    this.remoteUpdatedAt = 0,
    this.pulledTotal = 0,
    this.pushedTotal = 0,
    this.pulled = const [],
    this.pushed = const [],
    this.error,
    this.via,
    this.etag,
    this.statEtag,
  });

  final int at;
  final int durationMs;
  final SyncOutcome outcome;
  final SyncTrigger trigger;

  /// 失败阶段：config / dir / get / parse / merge / put / meta。
  final String? phase;
  final int revBefore;
  final int revAfter;
  final bool uploaded;
  final String remoteDeviceId;
  final int remoteUpdatedAt;
  final int pulledTotal;
  final int pushedTotal;
  final List<SyncLogChange> pulled;
  final List<SyncLogChange> pushed;
  final String? error;

  /// 这次走的网络路径：stat（PROPFIND 命中）/ 304（条件 GET）/ get / put。
  final String? via;

  /// 本次使用的云端 ETag（排障用；不是凭据）。
  final String? etag;

  /// PROPFIND 返回的 ETag；为空说明 stat 不可用。
  final String? statEtag;

  DateTime get atTime => DateTime.fromMillisecondsSinceEpoch(at);

  bool get ok => outcome == SyncOutcome.success;

  Map<String, dynamic> toJson() => {
    'at': at,
    'ms': durationMs,
    'out': outcome.wire,
    'trig': trigger.wire,
    if (phase != null) 'ph': phase,
    'rev': [revBefore, revAfter],
    'up': uploaded,
    if (remoteDeviceId.isNotEmpty) 'dev': remoteDeviceId,
    if (remoteUpdatedAt > 0) 'rup': remoteUpdatedAt,
    'pt': pulledTotal,
    'qt': pushedTotal,
    if (pulled.isNotEmpty)
      'pull': [for (final change in pulled) change.toJson()],
    if (pushed.isNotEmpty)
      'push': [for (final change in pushed) change.toJson()],
    if (error != null) 'err': error,
    if (via != null) 'via': via,
    if (etag != null) 'et': etag,
    if (statEtag != null) 'st': statEtag,
  };

  static SyncLogRun? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final rev = asList(json['rev']);
    return SyncLogRun(
      at: asInt(json['at']),
      durationMs: asInt(json['ms']),
      outcome: SyncOutcome.parse(json['out']),
      trigger: SyncTrigger.parse(json['trig']),
      phase: asString(json['ph']).isEmpty ? null : asString(json['ph']),
      revBefore: rev.isEmpty ? 0 : asInt(rev[0]),
      revAfter: rev.length < 2 ? 0 : asInt(rev[1]),
      uploaded: json['up'] == true,
      remoteDeviceId: asString(json['dev']),
      remoteUpdatedAt: asInt(json['rup']),
      pulledTotal: asInt(json['pt']),
      pushedTotal: asInt(json['qt']),
      pulled: [
        for (final change in asList(json['pull']))
          ?SyncLogChange.tryFromJson(change),
      ],
      pushed: [
        for (final change in asList(json['push']))
          ?SyncLogChange.tryFromJson(change),
      ],
      error: asString(json['err']).isEmpty ? null : asString(json['err']),
      via: asString(json['via']).isEmpty ? null : asString(json['via']),
      etag: asString(json['et']).isEmpty ? null : asString(json['et']),
      statEtag: asString(json['st']).isEmpty ? null : asString(json['st']),
    );
  }
}

/// 本地同步日志：`<AppSupport>/sync-log.json`，只留最近 [maxRuns] 次。
///
/// 不进 `library.db`（那个库删了等于清空书架），也不进同步载荷——它是本机诊断
/// 数据，两台设备各记各的。
class SyncLogStore {
  static const int maxRuns = 50;
  static const int maxChangesPerDirection = 20;

  /// 测试注入用；为 null 时落到 `<AppSupport>/sync-log.json`。
  static String? overridePath;

  Future<File> _file() async {
    final path =
        overridePath ??
        '${(await getApplicationSupportDirectory()).path}/sync-log.json';
    return File(path);
  }

  Future<List<SyncLogRun>> read() async {
    final file = await _file();
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];
      return [
        for (final raw in asList(decoded['runs'])) ?SyncLogRun.tryFromJson(raw),
      ];
    } catch (_) {
      // 坏文件按空日志处理；下一次写入会覆盖它。
      return const [];
    }
  }

  /// 追加一条，超出上限的旧记录丢掉。
  ///
  /// 调用方要保证这是 best-effort：日志写失败绝不能影响同步结果。
  Future<void> append(SyncLogRun run) async {
    final runs = [run, ...await read()];
    final kept = runs.take(maxRuns).toList();
    await writeJsonAtomically(await _file(), {
      'v': 1,
      'runs': [for (final item in kept) item.toJson()],
    });
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}

final syncLogStoreProvider = Provider<SyncLogStore>((ref) => SyncLogStore());

/// 同步记录页的数据源；同步完成后页面自己 invalidate 即可。
final syncLogRunsProvider = FutureProvider<List<SyncLogRun>>(
  (ref) => ref.watch(syncLogStoreProvider).read(),
);

/// 比较两份同步载荷，返回变化明细（按 key 升序，便于测试与稳定展示）。
///
/// `before` 是变化前、`after` 是变化后。同步层两个方向各算一次：
/// 拉取 = diff(本地合并前, 本地合并后)，上传 = diff(云端, 合并结果)。
List<SyncLogChange> diffLibraryData(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  final beforeIndex = _index(before);
  final afterIndex = _index(after);
  final keys = <String>{...beforeIndex.keys, ...afterIndex.keys}.toList()
    ..sort();

  final changes = <SyncLogChange>[];
  for (final key in keys) {
    final old = beforeIndex[key];
    final current = afterIndex[key];
    if (old == null && current == null) continue;
    final fields = <SyncLogField>[];
    if (old == null) {
      _describeNew(current!, fields);
    } else if (current == null) {
      _describeGone(old, fields);
    } else {
      _describeDiff(old, current, fields);
    }
    if (fields.isEmpty) continue;
    final title = (current?.title.isNotEmpty ?? false)
        ? current!.title
        : (old?.title ?? '');
    changes.add(
      SyncLogChange(
        key: key,
        type: current?.type ?? old!.type,
        title: title,
        fields: fields,
      ),
    );
  }
  return changes;
}

Map<String, LibraryRecord> _index(Map<String, dynamic> data) {
  final out = <String, LibraryRecord>{};
  for (final raw in asList(data['items'])) {
    final record = LibraryRecord.tryFromJson(raw);
    if (record != null) out[record.key] = record;
  }
  return out;
}

void _describeNew(LibraryRecord record, List<SyncLogField> fields) {
  if (record.title.isNotEmpty) {
    fields.add(const SyncLogField(field: 'title', before: '—', after: '新增'));
  }
  if (record.hasProgress) {
    fields.add(
      SyncLogField(
        field: 'progress',
        before: '—',
        after: _progressText(record),
      ),
    );
  }
  if (record.onShelf) {
    fields.add(const SyncLogField(field: 'shelf', before: '—', after: '加入'));
  }
}

void _describeGone(LibraryRecord record, List<SyncLogField> fields) {
  if (record.title.isNotEmpty) {
    fields.add(const SyncLogField(field: 'title', before: '存在', after: '—'));
  }
  if (record.hasProgress) {
    fields.add(
      SyncLogField(
        field: 'progress',
        before: _progressText(record),
        after: '—',
      ),
    );
  }
  if (record.onShelf) {
    fields.add(const SyncLogField(field: 'shelf', before: '加入', after: '移出'));
  }
}

void _describeDiff(
  LibraryRecord old,
  LibraryRecord current,
  List<SyncLogField> fields,
) {
  void snapshot(
    String field,
    String before,
    String after,
    String Function(String) render,
  ) {
    if (before == after) return;
    fields.add(
      SyncLogField(field: field, before: render(before), after: render(after)),
    );
  }

  snapshot('title', old.title, current.title, _shortText);
  snapshot('author', old.author, current.author, _shortText);
  snapshot('intro', old.intro, current.intro, _shortText);
  if (old.cover != current.cover) {
    fields.add(
      SyncLogField(
        field: 'cover',
        before: old.cover.isEmpty ? '—' : '旧封面',
        after: current.cover.isEmpty ? '—' : '新封面',
      ),
    );
  }
  if (old.episodeCount != current.episodeCount) {
    fields.add(
      SyncLogField(
        field: 'episodeCount',
        before: '${old.episodeCount} 集',
        after: '${current.episodeCount} 集',
      ),
    );
  }
  if (old.lastReadAt != current.lastReadAt) {
    fields.add(
      SyncLogField(
        field: 'progress',
        before: _progressText(old),
        after: _progressText(current),
      ),
    );
  }
  if (old.onShelf != current.onShelf) {
    fields.add(
      SyncLogField(
        field: 'shelf',
        before: old.onShelf ? '加入' : '移出',
        after: current.onShelf ? '加入' : '移出',
      ),
    );
  }
}

String _progressText(LibraryRecord record) {
  if (!record.hasProgress) return '—';
  if (record.type == LibraryType.playlet) {
    return '第 ${record.progressIndex + 1} 集';
  }
  return '第 ${record.progressIndex + 1} 章 · 第 ${record.progressSub + 1} 段';
}

String _shortText(String value) {
  if (value.isEmpty) return '—';
  return value.length <= 20 ? value : '${value.substring(0, 20)}…';
}
