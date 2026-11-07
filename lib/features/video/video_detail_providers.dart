import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/chapter.dart';
import '../../data/models/video_detail.dart';
import '../cache/cache_providers.dart';

/// 短剧详情页一屏所需的全部数据：详情 + 选集。
class VideoDetailBundle {
  const VideoDetailBundle({required this.detail, required this.episodes});

  final VideoDetail detail;
  final List<Chapter> episodes;
}

/// 详情与选集并行取。
///
/// 两个接口互不依赖，放在同一个 provider 里 Future.wait：页面因此只有一份
/// 加载态、一份错误态，不会出现「详情已出、选集还在转」的割裂感。
///
/// 用 autoDispose：选集可能有几百上千集，退出详情页后没必要长期驻留内存。
///
/// 在线失败时回退到离线区的 `series.json` manifest（剧名/封面/选集）：
/// 断网也能从「我的」或列表进详情，选集里已缓存的集由播放页用本地文件秒开
/// （见 docs/offline-cache.md §6.2）。没有离线 manifest 才把错误交给页面。
///
/// 和 `detail_providers.dart` 的 [detailBundleProvider] 一样，这里关掉
/// Riverpod 3 的默认自动重试（10 次、约 38 秒）：短剧详情失败就是「选集拉
/// 不到，没法播放」，应当立刻把错误页和重试按钮交给用户，而不是在后台反复
/// 重试、让页面在错误页与加载态之间闪。
final videoDetailBundleProvider = FutureProvider.autoDispose
    .family<VideoDetailBundle, String>((ref, seriesId) async {
      final api = ref.watch(apiClientProvider);
      try {
        // Future.wait 会原样抛出第一个失败（ApiException），页面才能拿到
        // 可直接展示的 message，而不是被 ParallelWaitError 包一层。
        final values = await Future.wait<Object>([
          api.videoDetail(seriesId),
          api.videoEpisodes(seriesId),
        ]);
        return VideoDetailBundle(
          detail: values[0] as VideoDetail,
          episodes: values[1] as List<Chapter>,
        );
      } catch (_) {
        final offline = await ref
            .read(offlineSeriesStoreProvider)
            .read(seriesId);
        if (offline == null) rethrow;
        return VideoDetailBundle(
          // manifest 里只有剧名/封面/集数：简介、分类、播放量都拿不到，
          // 留空即可，页面本来就有 preview 兜底。
          detail: VideoDetail(
            id: seriesId,
            title: offline.title,
            cover: offline.cover,
            episodeCount: offline.total,
          ),
          episodes: [
            for (final episode in offline.episodes)
              Chapter(
                id: episode.id,
                title: episode.title,
                index: episode.index,
              ),
          ],
        );
      }
    }, retry: (retryCount, error) => null);
