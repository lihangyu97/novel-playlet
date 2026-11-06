import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/feed/feed_state.dart';
import 'package:novel_playlet/data/models/video_detail.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/data/models/video_source.dart';
import 'package:novel_playlet/data/parsers/video_parsers.dart';

/// 视频域解析测试：只用 JSON，不联网、不启内核。
///
/// 短剧卡片的字段名与位置都比小说更飘（`video_data` / `video_detail` /
/// 扁平卡三种形态），解析兼容只有单测兜得住。
void main() {
  group('parseVideoSeries', () {
    test('模板卡的 video_data[].video_detail 能取到', () {
      final items = parseVideoSeries({
        'data': {
          'tab_item': [
            {
              'cell_data': [
                {
                  'cell_id': 'c1',
                  'video_data': [
                    {
                      'video_detail': {
                        'series_id_str': '7526874845758376985',
                        'series_title': '总裁的替身新娘',
                        'series_cover': 'https://example.com/cover.jpg',
                        'series_intro': '简介',
                        'episode_cnt': 80,
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      });
      expect(items, hasLength(1));
      expect(items.first.id, '7526874845758376985');
      expect(items.first.title, '总裁的替身新娘');
      expect(items.first.episodeCount, 80);
    });

    test('扁平卡直挂字段也能取到，数字型 id 优先取 series_id_str', () {
      final items = parseVideoSeries({
        'data': {
          'cell_data': [
            {
              'series_id': 123,
              'series_id_str': '123',
              'title': '直挂短剧',
              'cover': 'https://example.com/b.jpg',
              'episode_cnt': '12',
            },
          ],
        },
      });
      expect(items.single.id, '123');
      expect(items.single.title, '直挂短剧');
      expect(items.single.episodeCount, 12);
    });

    test('小说卡片不会被误收成短剧', () {
      final items = parseVideoSeries({
        'data': {
          'cell_data': [
            {'book_id': 'b1', 'title': '一本小说', 'thumb_url': 'x'},
          ],
        },
      });
      expect(items, isEmpty);
    });

    test('同一部剧在多个区块出现只保留一条', () {
      final items = parseVideoSeries({
        'data': {
          'items': [
            {'series_id': 's1', 'title': 'A'},
            {'series_id': 's1', 'title': 'A'},
          ],
        },
      });
      expect(items, hasLength(1));
    });
  });

  group('VideoDetail', () {
    test('从 data.video_data 取详情', () {
      final detail = VideoDetail.fromPayload({
        'code': 0,
        'data': {
          'video_data': {
            'series_id_str': 's1',
            'series_title': '剧名',
            'series_cover': 'https://example.com/c.jpg',
            'series_intro': '简介',
            'episode_cnt': 24,
            'series_play_cnt': 120000,
            'category_schema': '[{"name":"都市"},{"name":"甜宠"}]',
          },
        },
      });
      expect(detail.title, '剧名');
      expect(detail.episodeCount, 24);
      expect(detail.categories, ['都市', '甜宠']);
    });

    test('业务失败返回 empty 而不是抛', () {
      final detail = VideoDetail.fromPayload({'code': 110001});
      expect(detail.isEmpty, isTrue);
    });
  });

  group('VideoSource', () {
    test('相对 /src 地址与清晰度列表', () {
      final source = VideoSource.fromPayload({
        'code': 0,
        'data': {
          'video_url': '/src/episode.mp4',
          'key_hex': '00ff',
          'variants': [
            {'name': '1080P', 'url': 'https://cdn/1080.mp4', 'height': 1080},
            {'name': '720P', 'url': 'https://cdn/720.mp4', 'height': 720},
          ],
        },
      });
      expect(source.url, '/src/episode.mp4');
      expect(source.keyHex, '00ff');
      expect(source.variants, hasLength(2));
      expect(source.variants.first.height, 1080);
    });

    test('没有地址时 isValid 为 false', () {
      final source = VideoSource.fromPayload({'code': 0, 'data': {}});
      expect(source.isValid, isFalse);
    });
  });

  group('漫剧元数据', () {
    test('tag_info / genre 标记的卡片识别为漫剧，普通短剧不是', () {
      final items = parseVideoSeries({
        'data': {
          'cell_data': [
            {
              'video_data': [
                {
                  'series_id_str': 'm1',
                  'series_title': '漫剧A',
                  'tag_info': {'text': '漫剧'},
                },
              ],
            },
            {
              'video_data': [
                {'series_id_str': 'v1', 'series_title': '短剧B'},
              ],
            },
          ],
        },
      });
      expect(items.map((item) => (item.id, item.isManju)), [
        ('m1', true),
        ('v1', false),
      ]);
    });

    test('标题/简介里提到漫剧不算证据', () {
      final items = parseVideoSeries({
        'data': {
          'cell_data': [
            {
              'video_data': [
                {
                  'series_id_str': 'x1',
                  'series_title': '漫剧原著改编',
                  'series_intro': '已改编为动态漫画',
                  'tag_info': {'text': '漫剧原著'},
                },
              ],
            },
          ],
        },
      });
      expect(items.single.isManju, isFalse);
    });

    test('book_data.genre=205 也能识别', () {
      final items = parseVideoSeries({
        'data': {
          'cell_data': [
            {
              'book_data': {
                'series_id_str': 'g1',
                'series_name': '漫剧G',
                'genre': '205',
              },
            },
          ],
        },
      });
      expect(items.single.isManju, isTrue);
    });
  });

  group('parseManjuSearchPage', () {
    Map<String, dynamic> payload({
      required int nextOffset,
      Object? hasMore,
    }) => {
      'code': 0,
      'data': {
        'search_tabs': [
          {
            'tab_type': 3,
            'title': '书籍',
            'data': [
              {
                'book_data': {'book_id': 'b1', 'book_name': '书'},
              },
            ],
          },
          {
            'tab_type': 11,
            'title': '短剧',
            'next_offset': nextOffset,
            'has_more': hasMore ?? true,
            'data': [
              {
                'video_data': {'series_id_str': 'v1', 'series_title': '短剧1'},
              },
              {
                'video_data': {
                  'series_id_str': 'm1',
                  'series_title': '漫剧1',
                  'tag_info': {'text': '漫剧'},
                },
              },
            ],
          },
        ],
      },
    };

    test('只保留漫剧卡片，游标挂在短剧 tab 上', () {
      final page = parseManjuSearchPage(payload(nextOffset: 10), offset: 0);
      expect(page.items.single.id, 'm1');
      expect(page.nextOffset, 10);
    });

    test('过滤后为空也暴露游标（避免把整条流误判到底）', () {
      final page = parseManjuSearchPage({
        'data': {
          'search_tabs': [
            {
              'tab_type': 11,
              'title': '短剧',
              'has_more': true,
              'next_offset': 23,
              'data': [
                {
                  'video_data': {'series_id_str': 'v1', 'series_title': '短剧1'},
                },
              ],
            },
          ],
        },
      }, offset: 0);
      expect(page.items, isEmpty);
      expect(page.nextOffset, 23);
    });

    test('has_more 但上游没给游标时按每页 10 条推进', () {
      final page = parseManjuSearchPage({
        'data': {
          'search_tabs': [
            {
              'tab_type': 11,
              'title': '短剧',
              'has_more': true,
              'data': [
                {
                  'video_data': {
                    'series_id_str': 'm1',
                    'series_title': '漫剧1',
                    'genre': 205,
                  },
                },
              ],
            },
          ],
        },
      }, offset: 10);
      expect(page.nextOffset, 20);
    });

    test('没有漫剧元数据时返回空，不把普通短剧当漫剧', () {
      final page = parseManjuSearchPage({
        'data': {
          'search_tabs': [
            {
              'tab_type': 11,
              'title': '短剧',
              'data': [
                {
                  'video_data': {'series_id_str': 'v1', 'series_title': '短剧1'},
                },
              ],
            },
          ],
        },
      }, offset: 0);
      expect(page.items, isEmpty);
      expect(page.nextOffset, isNull);
    });
  });

  group('parseSearchVideoSeries', () {
    Map<String, dynamic> multiTabPayload() => {
      'code': 0,
      'data': {
        'search_tabs': [
          {
            'tab_type': 3,
            'data': [
              {
                'book_data': {'book_id': 'n1', 'book_name': '书'},
              },
            ],
          },
          {
            'tab_type': 8,
            'data': [
              {
                'video_data': {'pseries_id': 'p1', 'series_name': '漫剧1'},
              },
            ],
          },
          {
            'tab_type': 11,
            'data': [
              {
                'video_data': {'series_id_str': 'v1', 'series_title': '短剧1'},
              },
            ],
          },
        ],
      },
    };

    test('多 tab 混排时只取 tab_type 匹配的那一个', () {
      expect(
        parseSearchVideoSeries(multiTabPayload(), tabType: 8).map((i) => i.id),
        ['p1'],
      );
      expect(
        parseSearchVideoSeries(multiTabPayload(), tabType: 11).map((i) => i.id),
        ['v1'],
      );
    });

    test('没有匹配 tab 时返回空，不把别的分类当本分类', () {
      expect(parseSearchVideoSeries(multiTabPayload(), tabType: 24), isEmpty);
    });

    test('响应完全没有 tab_type 元信息时退回整包解析', () {
      final legacy = {
        'code': 0,
        'data': {
          'search_tabs': [
            {
              'data': [
                {
                  'video_data': {'series_id_str': 'x1', 'series_title': '旧短剧'},
                },
              ],
            },
          ],
        },
      };
      final items = parseSearchVideoSeries(legacy, tabType: 11);
      expect(items.single.id, 'x1');
    });
  });

  group('FeedState<VideoSeries>', () {
    test('追加分页时按 id 去重，游标不前进视为到底', () {
      final initial = FeedState<VideoSeries>.feed(
        items: const [VideoSeries(id: 's1', title: 'A')],
        nextOffset: 10,
      );
      final next = initial.appendPage(
        newItems: const [
          VideoSeries(id: 's1', title: 'A'),
          VideoSeries(id: 's2', title: 'B'),
        ],
        idOf: (item) => item.id,
        nextOffset: 10,
      );
      expect(next.items.map((item) => item.id), ['s1', 's2']);
      expect(next.hasMore, isFalse);
    });

    test('FeedState 字段级相等：加载态/错误态变化算不同', () {
      final state = FeedState<VideoSeries>.feed(
        items: const [VideoSeries(id: 's1', title: 'A')],
        nextOffset: 10,
      );
      expect(
        state,
        FeedState<VideoSeries>.feed(
          items: const [VideoSeries(id: 's1', title: 'A')],
          nextOffset: 10,
        ),
      );
      expect(
        state,
        isNot(
          FeedState<VideoSeries>.feed(
            items: const [VideoSeries(id: 's1', title: 'A')],
            nextOffset: 10,
          ).withLoadingMore(true),
        ),
      );
    });
  });

  group('模型相等性', () {
    test('VideoSeries 按所有参与展示的字段比较（不是只比 id）', () {
      const a = VideoSeries(
        id: 'v1',
        title: '剧A',
        cover: 'a.jpg',
        intro: '简介',
        episodeCount: 12,
        isManju: true,
      );
      expect(
        a,
        const VideoSeries(
          id: 'v1',
          title: '剧A',
          cover: 'a.jpg',
          intro: '简介',
          episodeCount: 12,
          isManju: true,
        ),
      );
      expect(a, isNot(const VideoSeries(id: 'v1', title: '剧A')));
    });
  });
}
