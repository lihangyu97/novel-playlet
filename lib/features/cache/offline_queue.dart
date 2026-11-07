import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/chapter.dart';
import 'offline_task.dart';

/// 队列中的一条任务：除展示快照外还带启动时需要的完整章节/选集列表。
///
/// 不放进 [OfflineQueue] 的 state：上千章的列表没必要让 UI 每次队列变化时重建。
class OfflineQueueJob {
  const OfflineQueueJob({
    required this.kind,
    required this.id,
    required this.title,
    required this.cover,
    required this.items,
  });

  final OfflineTaskKind kind;
  final String id;
  final String title;
  final String cover;

  /// 小说章节列表 / 短剧选集列表（`start*` 需要完整列表算缺口）。
  final List<Chapter> items;
}

/// 离线下载队列：单任务下载器同一时刻只跑一个任务，其余 FIFO 等待。
///
/// 为什么独立成 Notifier 而不是塞进下载器 state：下载器 state 是「当前任务」
/// 的展示快照（详情按钮/缓存中心都 watch 它），队列是另一份会独立变化的列表；
/// 拆开后 UI 可以单独 watch 队列，下载器内部仍保持单任务状态机。
///
/// 队列只在内存里：进程重启后消失（当前任务会被恢复成 paused），用户重新点
/// 「缓存」即可——离线区按文件缺口续传，不会重复下载。
class OfflineQueue extends Notifier<List<OfflineQueuedTask>> {
  final List<OfflineQueueJob> _jobs = [];

  /// 队列长度上限：误点/批量点也不至于无限堆。
  static const int maxLength = 20;

  @override
  List<OfflineQueuedTask> build() => const [];

  /// 队列里是否已有这本书/这部剧（含正在跑的不算，见下载器）。
  bool contains(OfflineTaskKind kind, String id) =>
      _jobs.any((job) => job.kind == kind && job.id == id);

  /// 入队；重复的 kind+id 只保留一条（幂等）。队列满抛
  /// [OfflineQueueFullException]，由 UI 提示用户。
  void enqueue(OfflineQueueJob job) {
    if (contains(job.kind, job.id)) return;
    if (_jobs.length >= maxLength) {
      throw const OfflineQueueFullException(maxLength);
    }
    _jobs.add(job);
    _publish();
  }

  /// 取队首并出队；队列空返回 null。
  OfflineQueueJob? takeFirst() {
    if (_jobs.isEmpty) return null;
    final job = _jobs.removeAt(0);
    _publish();
    return job;
  }

  /// 移除某本书/某部剧（删除离线内容、用户取消排队时）。
  bool remove(OfflineTaskKind kind, String id) {
    final before = _jobs.length;
    _jobs.removeWhere((job) => job.kind == kind && job.id == id);
    if (_jobs.length == before) return false;
    _publish();
    return true;
  }

  void clear() {
    if (_jobs.isEmpty) return;
    _jobs.clear();
    _publish();
  }

  void _publish() {
    state = [
      for (final job in _jobs)
        OfflineQueuedTask(
          kind: job.kind,
          id: job.id,
          title: job.title,
          cover: job.cover,
        ),
    ];
  }
}

/// 队列已满（最多 [maxLength] 个等待任务）。
class OfflineQueueFullException implements Exception {
  const OfflineQueueFullException(this.maxLength);

  final int maxLength;

  @override
  String toString() => 'OfflineQueueFullException(max=$maxLength)';
}
