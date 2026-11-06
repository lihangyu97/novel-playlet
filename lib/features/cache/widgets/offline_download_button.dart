import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/chapter.dart';
import '../../../data/models/json_utils.dart';
import '../cache_providers.dart';
import '../offline_downloader.dart';
import '../offline_task.dart';

/// 通用的「离线缓存」三态按钮（小说详情"缓存整本" / 短剧详情"缓存整剧"共用）。
///
/// 只依赖 `features/cache` 的公开 API，不 import 任何具体页面：
/// - 未缓存：下载图标，点击开始；
/// - 进行中：环形进度 + 百分比，点击暂停；暂停态再点继续；
/// - 已缓存：勾选图标，点击提示去「设置 → 存储」管理。
///
/// [items] 是整本的章节列表 / 整剧的选集列表（`start*` 需要完整列表才能算
/// 缺口与总进度）。缓存状态来自离线区 manifest（而非任务表），因此进程重启后
/// 依然能正确显示"已缓存/继续缓存"。
class OfflineDownloadButton extends ConsumerWidget {
  const OfflineDownloadButton({
    super.key,
    required this.kind,
    required this.id,
    required this.title,
    required this.cover,
    required this.items,
  });

  final OfflineTaskKind kind;

  /// 小说 bookId / 短剧 seriesId。
  final String id;
  final String title;
  final String cover;
  final List<Chapter> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(offlineDownloaderProvider);
    final cachedCompleted = kind == OfflineTaskKind.novel
        ? (ref.watch(offlineNovelProvider(id)).value?.completed ?? 0)
        : (ref.watch(offlineSeriesProvider(id)).value?.completed ?? 0);
    final cachedTotal = kind == OfflineTaskKind.novel
        ? (ref.watch(offlineNovelProvider(id)).value?.total ?? 0)
        : (ref.watch(offlineSeriesProvider(id)).value?.total ?? 0);
    final isCached = cachedTotal > 0 && cachedCompleted >= cachedTotal;
    final active = task != null && task.kind == kind && task.id == id;

    if (active && task.isRunning) {
      return _ProgressButton(
        task: task,
        onPressed: () => ref.read(offlineDownloaderProvider.notifier).pause(),
        tooltip: '暂停缓存',
      );
    }
    if (active && task.isPaused) {
      return _ProgressButton(
        task: task,
        onPressed: () => _resume(context, ref),
        tooltip: '继续缓存',
      );
    }
    // done 直接显示勾选（manifest 可能还没被 provider 刷新，不能只依赖 isCached）。
    if (active && task.isDone) {
      return IconButton(
        tooltip: '已离线缓存',
        onPressed: () => _showMessage(context, '已离线缓存，可在 设置 → 存储 管理'),
        icon: const Icon(Icons.offline_pin_rounded),
      );
    }
    if (isCached) {
      return IconButton(
        tooltip: '已离线缓存',
        onPressed: () => _showMessage(context, '已离线缓存，可在 设置 → 存储 管理'),
        icon: const Icon(Icons.offline_pin_rounded),
      );
    }
    return IconButton(
      tooltip: '离线缓存',
      onPressed: () => _start(context, ref),
      icon: const Icon(Icons.download_rounded),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final downloader = ref.read(offlineDownloaderProvider.notifier);
    try {
      switch (kind) {
        case OfflineTaskKind.novel:
          await downloader.startNovelBook(
            bookId: id,
            title: title,
            cover: cover,
            chapters: items,
          );
        case OfflineTaskKind.video:
          await downloader.startVideoSeries(
            seriesId: id,
            title: title,
            cover: cover,
            episodes: items,
          );
      }
    } on OfflineQuotaExceeded catch (error) {
      if (!context.mounted) return;
      _showMessage(
        context,
        '离线区空间不足（已用 ${_formatBytes(error.usedBytes)} / 上限 '
        '${_formatBytes(error.capBytes)}），请先在 设置 → 存储 清理',
      );
    } on OfflineTaskBusyException {
      if (!context.mounted) return;
      _showMessage(context, '当前有缓存任务进行中，完成后再试');
    } catch (error) {
      if (!context.mounted) return;
      _showMessage(context, apiErrorCopy(error, fallback: '离线缓存失败，请重试'));
    }
  }

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final downloader = ref.read(offlineDownloaderProvider.notifier);
    // 本进程内暂停：resume() 直接接着跑；进程重启后的恢复态任务没有内存里的
    // 入参，重新调用 start（幂等，按文件缺口续传）。
    final resumed = await downloader.resume();
    if (resumed || !context.mounted) return;
    await _start(context, ref);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ProgressButton extends StatelessWidget {
  const _ProgressButton({
    required this.task,
    required this.onPressed,
    required this.tooltip,
  });

  final OfflineTask task;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final percent = (task.progress * 100).round();
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: task.total > 0 ? task.progress : null,
                ),
              ),
              const SizedBox(width: 6),
              Text('$percent%', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
