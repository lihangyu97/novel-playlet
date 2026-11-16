import 'package:novel_playlet/features/sync/sync_log.dart';

/// 内存版同步日志：widget 测试里没有真实文件 IO（FakeAsync 下不会完成）。
class MemorySyncLogStore extends SyncLogStore {
  MemorySyncLogStore([List<SyncLogRun>? initial]) : _runs = [...?initial];

  final List<SyncLogRun> _runs;

  @override
  Future<List<SyncLogRun>> read() async => List.unmodifiable(_runs);

  @override
  Future<void> append(SyncLogRun run) async {
    _runs.insert(0, run);
    if (_runs.length > SyncLogStore.maxRuns) {
      _runs.removeRange(SyncLogStore.maxRuns, _runs.length);
    }
  }

  @override
  Future<void> clear() async => _runs.clear();
}
