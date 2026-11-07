import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 离线整剧下载的清晰度上限。
///
/// 值语义是「短边不超过 N 的最高档」，与内核 `?max_height=` 一致；`best` 表示
/// 不设上限（历史上线行为）。默认 720P：短剧 3 GiB 离线额度下，720P 能多存
/// 一倍集数，流量也更可控。
enum VideoDownloadQuality {
  best(0, '最高'),
  p1080(1080, '1080P'),
  p720(720, '720P'),
  p480(480, '480P');

  const VideoDownloadQuality(this.maxHeight, this.label);

  final int maxHeight;
  final String label;

  /// 内核按档选流时不传 max_height（0 = 最高档）。
  int? get kernelMaxHeight => maxHeight > 0 ? maxHeight : null;

  static VideoDownloadQuality fromMaxHeight(int maxHeight) => values.firstWhere(
    (quality) => quality.maxHeight == maxHeight,
    orElse: () => VideoDownloadQuality.best,
  );
}

final videoDownloadQualityProvider =
    NotifierProvider<VideoDownloadQualityController, VideoDownloadQuality>(
      VideoDownloadQualityController.new,
    );

class VideoDownloadQualityController extends Notifier<VideoDownloadQuality> {
  static const prefsKey = 'video_download_quality_v1';

  /// 磁盘读取返回前用户就改过设置时，不能被旧值覆盖。
  bool _userChanged = false;

  @override
  VideoDownloadQuality build() {
    _restore();
    return VideoDownloadQuality.p720;
  }

  void setQuality(VideoDownloadQuality quality) {
    if (quality == state) return;
    _userChanged = true;
    state = quality;
    _persist(quality);
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _userChanged) return;
      final stored = prefs.getInt(prefsKey);
      if (stored == null) return;
      final quality = VideoDownloadQuality.fromMaxHeight(stored);
      if (quality != state) state = quality;
    } catch (_) {
      // 读不到偏好就用默认 720P。
    }
  }

  Future<void> _persist(VideoDownloadQuality quality) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setInt(prefsKey, quality.maxHeight);
    } catch (_) {
      // 落盘失败只影响下次启动的默认值，本次选择仍生效。
    }
  }
}
