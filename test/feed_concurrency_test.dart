import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/recommend/recommend_controller.dart';
import 'package:novel_playlet/features/recommend/recommend_state.dart';
import 'package:novel_playlet/features/video/video_controller.dart';
import 'package:novel_playlet/features/video/video_state.dart';

/// 回归：翻页请求必须串行。
///
/// 真机日志里出现过同一 offset 每 13ms 连发一次、并发响应互相覆盖的请求风暴，
/// 根因是 `withLoadMoreError` 把 `loadingMore` 重置成 false，守卫失效。这个
/// 文件同时锁"状态 copy 保留字段"和"并发调用只发一个请求"。
class _SlowFake extends BackendTransport {
  _SlowFake(this.video) : super(port: 0);

  final bool video;
  final calls = <String>[];

  Map<String, dynamic> _payload(int offset) {
    if (video) {
      return {
        'code': 0,
        'data': {
          'tab_index': 0,
          'tab_item': [
            {
              'tab_type': 8,
              'title': '看剧',
              'next_offset': offset + 1,
              'session_id': 'sess',
              'cell_data': [
                {
                  'video_data': [
                    for (var i = 0; i < 6; i++)
                      {
                        'series_id': '${offset}_$i',
                        'title': '剧$offset-$i',
                        'cover': '',
                      },
                  ],
                },
              ],
            },
          ],
        },
      };
    }
    return {
      'code': 0,
      'data': {
        'tab_index': 0,
        'tab_item': [
          {
            'tab_type': 2,
            'title': '推荐',
            'next_offset': offset + 1,
            'session_id': 'sess',
            'cell_data': [
              {
                'book_data': [
                  for (var i = 0; i < 6; i++)
                    {
                      'book_id': 'b${offset}_$i',
                      'book_name': '书$offset-$i',
                    },
                ],
              },
            ],
          },
        ],
      },
    };
  }

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    final q = Uri.splitQueryString(query ?? '');
    final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
    calls.add('${q['tab_type']}@$offset');
    // 给并发留出窗口：真实网络下这个间隙足够第二次调用挤进来。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(_payload(offset)))),
      'application/json',
    );
  }
}

void main() {
  group('asLoadMore 状态字段', () {
    test('VideoFeedState.withLoadMoreError 保留 loadingMore', () {
      final state = VideoFeedState.feed(items: const <VideoSeries>[])
          .withLoadingMore(true)
          .withLoadMoreError('boom');
      expect(state.loadingMore, isTrue, reason: '清错误不能把 loadingMore 清掉');
      expect(state.loadMoreError, 'boom');
    });

    test('RecommendState.withLoadMoreError 保留 loadingMore', () {
      final state = RecommendState.feed(
        items: const [],
      ).withLoadingMore(true).withLoadMoreError('boom');
      expect(state.loadingMore, isTrue);
      expect(state.loadMoreError, 'boom');
    });
  });

  test('短剧：并发 loadMore 只发一个请求', () async {
    final fake = _SlowFake(true);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
    );
    addTearDown(container.dispose);
    await container.read(videoFeedControllerProvider.future);
    final notifier = container.read(videoFeedControllerProvider.notifier);
    await Future.wait<void>([notifier.loadMore(), notifier.loadMore()]);
    expect(fake.calls, ['8@0', '8@1'], reason: '第二次并发调用必须被重入锁挡掉');
  });

  test('小说：并发 loadMore 只发一个请求', () async {
    final fake = _SlowFake(false);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
    );
    addTearDown(container.dispose);
    await container.read(recommendControllerProvider.future);
    final notifier = container.read(recommendControllerProvider.notifier);
    await Future.wait<void>([notifier.loadMore(), notifier.loadMore()]);
    expect(fake.calls, ['2@0', '2@1']);
  });
}
