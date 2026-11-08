import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/json_utils.dart';

/// 离线任务类型（小说整本 / 短剧整剧）。
enum OfflineTaskKind { novel, video }

/// 任务状态机：idle → running → (paused | done | failed)；cancel 不是状态，
/// 取消后直接清掉任务记录（已下载内容保留）。
enum OfflineTaskStatus { idle, running, paused, done, failed }

/// 一个离线下载任务的持久化快照（SharedPreferences `offline_task_v1`）。
///
/// 只记录"进度 + 展示信息"，不记录章节/剧集列表：恢复时以离线区 manifest
/// 与文件存在为准，任务表只负责告诉用户"上次哪个任务没跑完"。
class OfflineTask {
  OfflineTask({
    required this.kind,
    required this.id,
    required this.title,
    this.cover = '',
    this.completed = 0,
    this.total = 0,
    this.bytes = 0,
    this.speedBytesPerSecond = 0,
    this.status = OfflineTaskStatus.idle,
    this.error,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final OfflineTaskKind kind;

  /// 小说是 bookId，短剧是 seriesId。
  final String id;
  final String title;
  final String cover;
  final int completed;
  final int total;
  final int bytes;

  /// 当前下载速度（字节/秒）。仅运行中有意义，**不持久化**：重启后为 0，
  /// 由下载器在下一批/下一集完成时重新采样。列表页用它展示「网速」。
  final int speedBytesPerSecond;

  final OfflineTaskStatus status;

  /// 暂停/失败时给用户看的一句原因；运行中/完成时为 null。
  final String? error;

  final DateTime updatedAt;

  bool get isRunning => status == OfflineTaskStatus.running;
  bool get isPaused => status == OfflineTaskStatus.paused;
  bool get isDone => status == OfflineTaskStatus.done;

  /// 0~1 的进度；total 为 0 时返回 0（避免除零）。
  double get progress =>
      total <= 0 ? 0 : (completed / total).clamp(0, 1).toDouble();

  OfflineTask copyWith({
    String? title,
    String? cover,
    int? completed,
    int? total,
    int? bytes,
    int? speedBytesPerSecond,
    OfflineTaskStatus? status,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
  }) => OfflineTask(
    kind: kind,
    id: id,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    completed: completed ?? this.completed,
    total: total ?? this.total,
    bytes: bytes ?? this.bytes,
    speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.wireName,
    'id': id,
    'title': title,
    'cover': cover,
    'completed': completed,
    'total': total,
    'bytes': bytes,
    'status': status.wireName,
    'error': error,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  /// 解析持久化任务；损坏/未知枚举值返回 null（当作没有任务）。
  static OfflineTask? tryFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    final kind = offlineTaskKindFromWire(json['kind']);
    final status = offlineTaskStatusFromWire(json['status']);
    final id = firstString(json, ['id', 'bookId', 'seriesId']);
    if (kind == null || status == null || id.isEmpty) return null;
    final millis = asInt(json['updatedAt']);
    return OfflineTask(
      kind: kind,
      id: id,
      title: asString(json['title']),
      cover: asString(json['cover']),
      completed: asInt(json['completed']),
      total: asInt(json['total']),
      bytes: asInt(json['bytes']),
      status: status,
      error: asString(json['error']).isEmpty ? null : asString(json['error']),
      updatedAt: millis > 0
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : DateTime.now(),
    );
  }
}

extension OfflineTaskKindWire on OfflineTaskKind {
  String get wireName => switch (this) {
    OfflineTaskKind.novel => 'novel',
    OfflineTaskKind.video => 'video',
  };
}

extension OfflineTaskStatusWire on OfflineTaskStatus {
  String get wireName => switch (this) {
    OfflineTaskStatus.idle => 'idle',
    OfflineTaskStatus.running => 'running',
    OfflineTaskStatus.paused => 'paused',
    OfflineTaskStatus.done => 'done',
    OfflineTaskStatus.failed => 'failed',
  };
}

OfflineTaskKind? offlineTaskKindFromWire(Object? value) {
  final wire = asString(value);
  for (final kind in OfflineTaskKind.values) {
    if (kind.wireName == wire) return kind;
  }
  return null;
}

OfflineTaskStatus? offlineTaskStatusFromWire(Object? value) {
  final wire = asString(value);
  for (final status in OfflineTaskStatus.values) {
    if (status.wireName == wire) return status;
  }
  return null;
}

/// 单任务状态持久化。读写失败都静默（任务进度不值得弹错）。
class OfflineTaskStore {
  OfflineTaskStore({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  /// 持久化 key（固定，见 docs/implementation.md）。
  static const String storageKey = 'offline_task_v1';

  final Future<SharedPreferences> Function() _preferences;

  Future<OfflineTask?> read() async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      return OfflineTask.tryFromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(OfflineTask task) async {
    try {
      final prefs = await _preferences();
      await prefs.setString(storageKey, jsonEncode(task.toJson()));
    } catch (_) {
      // 进度持久化失败不影响本次下载。
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await _preferences();
      await prefs.remove(storageKey);
    } catch (_) {
      // 同上。
    }
  }
}

/// 任务状态的用户可读文案（缓存中心列表 / 详情页按钮共用）。
///
/// 注意 done 必须显示「已完成」：之前只区分 active/paused，会把下完的任务
/// 显示成「已暂停」。
String offlineTaskStatusLabel(OfflineTaskStatus status) => switch (status) {
  OfflineTaskStatus.idle => '未开始',
  OfflineTaskStatus.running => '下载中…',
  OfflineTaskStatus.paused => '已暂停',
  OfflineTaskStatus.done => '已完成',
  OfflineTaskStatus.failed => '下载失败',
};

/// 排队中的离线任务快照（缓存中心/详情按钮展示用）。
///
/// 完整章节/选集列表留在队列内部（[OfflineQueueJob]），UI 只需要展示信息的
/// 轻量快照，避免队列状态里塞进上千章的列表。
class OfflineQueuedTask {
  const OfflineQueuedTask({
    required this.kind,
    required this.id,
    required this.title,
    required this.cover,
  });

  final OfflineTaskKind kind;

  /// 小说 bookId / 短剧 seriesId。
  final String id;
  final String title;
  final String cover;
}
