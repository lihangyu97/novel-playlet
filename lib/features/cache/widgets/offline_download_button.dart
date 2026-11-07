import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../app/widgets/detail_icon_label_button.dart';
import '../../../data/models/chapter.dart';
import '../../../data/models/json_utils.dart';
import '../cache_providers.dart';
import '../offline_downloader.dart';
import '../offline_task.dart';

/// 通用的「离线缓存」入口（小说详情「缓存整本」/ 短剧详情「缓存整剧」共用）。
///
/// 与左侧收藏按钮同一套线条风格（[DetailIconLabelButton]），三态：
/// - `缓存`（download_outlined）：没有离线内容，或上次任务失败；点击开始/重试。
/// - `缓存中`（downloading_outlined）：任务进行中/暂停，或 manifest 只完成一部分；
///   点击进缓存中心看进度（暂停/继续都由缓存中心负责）。
/// - `已缓存`（download_done_outlined）：manifest 完整或任务完成；点击进缓存中心。
///
/// [items] 是整本的章节列表 / 整剧的选集列表（`start*` 需要完整列表才能算
/// 缺口与总进度）。缓存状态来自离线区 manifest（而非任务表），因此进程重启后
/// 依然能正确显示「已缓存/缓存中」。
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
    final manifestComplete = cachedTotal > 0 && cachedCompleted >= cachedTotal;
    final active = task != null && task.kind == kind && task.id == id;
    // done 直接算已缓存：manifest 可能还没被 provider 刷新，不能只依赖 isCached。
    final isCached = manifestComplete || (active && task.isDone);
    // 任务失败回到「缓存」态（点击即重新 start，下载器会按文件缺口续传）；
    // 没有活动任务但 manifest 只完成了一部分（取消/重启残留）也算缓存中。
    final inProgress =
        !isCached &&
        (active
            ? (task.isRunning || task.isPaused)
            : (cachedTotal > 0 && cachedCompleted > 0));

    final IconData icon;
    final String label;
    if (isCached) {
      icon = Icons.download_done_outlined;
      label = '已缓存';
    } else if (inProgress) {
      icon = Icons.downloading_outlined;
      label = '缓存中';
    } else {
      icon = Icons.download_outlined;
      label = '缓存';
    }
    return DetailIconLabelButton(
      icon: icon,
      label: label,
      active: isCached || inProgress,
      // 缓存中/已缓存都交给缓存中心：那里能看进度，也能暂停/继续/重试。
      onTap: isCached || inProgress
          ? () => context.pushAppRoute(const CacheCenterRoute())
          : () => _start(context, ref),
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

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
