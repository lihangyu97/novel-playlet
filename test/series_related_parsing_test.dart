import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/parsers/video_parsers.dart';

/// 内核 `/api/v1/series/{id}/related` 返回官方 `data[].video_data[]`，
/// 复用短剧卡片解析：递归展开、按 series id 去重、保留首次出现顺序。
void main() {
  test('相关系列响应按 data[].video_data[] 展开并去重', () {
    final payload = <String, dynamic>{
      'code': 0,
      'data': [
        {
          'video_data': [
            {'series_id': 's1', 'title': '第一季', 'episode_cnt': 30},
            {'series_id': 's2', 'title': '第二季', 'episode_cnt': 36},
            {'series_id': 's2', 'title': '重复项'},
            {'video_id': 'v1', 'title': '单集片段'},
          ],
        },
        {
          'video_data': [
            {'series_id': 's3', 'title': '第三季'},
          ],
        },
      ],
    };

    final items = parseVideoSeries(payload);
    expect(items.map((item) => item.id), ['s1', 's2', 'v1', 's3']);
    expect(items[1].episodeCount, 36);
    expect(items[1].title, '第二季');
  });
}
