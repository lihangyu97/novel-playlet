import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';

/// S3：离线 manifest 的清晰度字段（向后兼容旧数据）。
void main() {
  test('旧 manifest 没有 quality 字段：按最高档/未知解析', () {
    final series = OfflineSeries.tryFromJson({
      'schema': 1,
      'kind': 'video',
      'seriesId': 's1',
      'title': '测试短剧',
      'episodes': [
        {'id': 'e1', 'title': '第1集', 'bytes': 10, 'cached': true},
      ],
      'completed': 1,
      'bytes': 10,
    })!;

    expect(series.qualityMaxHeight, 0);
    expect(series.episodes.single.variantName, '');
    expect(series.episodes.single.shortEdge, 0);
    expect(qualityLabelOf(series), '');
  });

  test('新字段 JSON 往返：请求上限 + 每集实际档位', () {
    final series = OfflineSeries(
      seriesId: 's1',
      title: '测试短剧',
      qualityMaxHeight: 720,
      episodes: const [
        OfflineEpisode(
          id: 'e1',
          title: '第1集',
          bytes: 123,
          cached: true,
          variantName: '720P',
          shortEdge: 720,
        ),
      ],
      completed: 1,
      bytes: 123,
    );

    final restored = OfflineSeries.tryFromJson(series.toJson())!;
    expect(restored.qualityMaxHeight, 720);
    expect(restored.episodes.single.variantName, '720P');
    expect(restored.episodes.single.shortEdge, 720);

    final summary = OfflineSeriesSummary.fromSeries(restored);
    expect(summary.qualityLabel, '720P');
  });
}
