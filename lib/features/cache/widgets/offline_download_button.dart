import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/router.dart';
import '../../../app/widgets/detail_circle_button.dart';
import '../../../data/models/chapter.dart';
import '../../../data/models/json_utils.dart';
import '../cache_providers.dart';
import '../offline_queue.dart';
import '../offline_downloader.dart';
import '../offline_task.dart';

/// 通用的「离线缓存」入口（小说详情「缓存整本」/ 短剧详情「缓存整剧」共用）。
///
/// 与收藏、播放/阅读两颗按钮同一套圆形悬浮样式（[DetailCircleButton]），
/// 在底栏中间，三态靠图标与配色表达（文案只给读屏）：
/// - `download_outlined`：没有离线内容，或上次任务失败；点击开始/重试。
/// - `downloading_outlined`：任务进行中/暂停、manifest 只完成一部分，
///   或已经在下载队列里排队；点击进缓存中心看进度（暂停/继续/取消排队都由
///   缓存中心负责）。
/// - `download_done_outlined`：manifest 完整或任务完成；点击进缓存中心。
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
    // 与阅读页顶部缓存文案共用同一份三态判定（见 offlineEntryStatusProvider），
    // 两个入口不会各算一套、各显示一个状态。
    final status = ref.watch(offlineEntryStatusProvider((kind: kind, id: id)));
    final isCached = status == OfflineEntryStatus.cached;
    final inProgress = status == OfflineEntryStatus.inProgress;

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
    return DetailCircleButton(
      icon: icon,
      semanticLabel: label,
      active: isCached || inProgress,
      // 缓存中/已缓存都交给缓存中心：那里能看进度，也能暂停/继续/重试。
      onTap: isCached || inProgress
          ? () => context.pushAppRoute(const CacheCenterRoute())
          : () => _start(context, ref),
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) =>
      startOfflineDownload(
        context,
        ref,
        kind: kind,
        id: id,
        title: title,
        cover: cover,
        items: items,
      );
}

/// 启动一次离线下载（小说整本 / 短剧整剧）。
///
/// 详情页「缓存」按钮与阅读页顶部「缓存小说」共用：入口不同，但入队回执、
/// 空间不足/队列满的引导、失败文案必须一致，避免两处各写一套。
Future<void> startOfflineDownload(
  BuildContext context,
  WidgetRef ref, {
  required OfflineTaskKind kind,
  required String id,
  required String title,
  required String cover,
  required List<Chapter> items,
}) async {
  final downloader = ref.read(offlineDownloaderProvider.notifier);
  try {
    final disposition = switch (kind) {
      OfflineTaskKind.novel => await downloader.startNovelBook(
        bookId: id,
        title: title,
        cover: cover,
        chapters: items,
      ),
      OfflineTaskKind.video => await downloader.startVideoSeries(
        seriesId: id,
        title: title,
        cover: cover,
        episodes: items,
      ),
    };
    if (disposition != OfflineStartDisposition.queued) return;
    if (!context.mounted) return;
    // 单任务下载器正在跑别的任务：这次点击只是入队，给用户一个明确回执，
    // 否则点了没反应会以为失败。
    _showMessage(context, '已加入缓存队列，等前面的任务完成后自动开始');
  } on OfflineQuotaExceeded catch (error) {
    if (!context.mounted) return;
    _showMessage(
      context,
      '离线区空间不足（已用 ${_formatBytes(error.usedBytes)} / 上限 '
      '${_formatBytes(error.capBytes)}），请先在「我的 → 缓存」页删除不需要的缓存',
    );
  } on OfflineQueueFullException catch (error) {
    if (!context.mounted) return;
    _showMessage(context, '缓存队列已满（最多 ${error.maxLength} 个），请先等前面的任务完成');
  } catch (error) {
    if (!context.mounted) return;
    _showMessage(context, apiErrorCopy(error, fallback: '离线缓存失败，请重试'));
  }
}

void _showMessage(BuildContext context, String message) {
  showAppSnackBar(context, message);
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
