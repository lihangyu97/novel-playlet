import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/features/recommend/recommend_category.dart';
import 'package:novel_playlet/features/recommend/recommend_controller.dart';
import 'package:novel_playlet/features/recommend/recommend_item.dart';
import 'package:novel_playlet/features/recommend/recommend_state.dart';

/// 回归：翻页请求必须串行。
///
/// 真机日志里出现过同一 offset 每 13ms 连发一次、并发响应互相覆盖的请求风暴，
/// 根因是 `withLoadMoreError` 把 `loadingMore` 重置成 false，守卫失效。这个
/// 文件同时锁"状态 copy 保留字段"和"并发调用只发一个请求"。
class _SlowFake extends BackendTransport {
  _SlowFake({this.cursorlessTab}) : super(port: 0);

  /// 模拟真实漫剧（24）没有游标：这些 tab 的 next_offset 恒为 0。
  final int? cursorlessTab;

  /// 记录 `tab_type@offset`，用来断言同一分类只发一次请求。
  final calls = <String>[];

  /// 首页流：小说（2）回书籍卡片，短剧/漫剧（8/24）回视频卡片，
  /// 这里的 `tab_type` 会原样反射到响应里，供 ApiClient 的认领校验通过。
  Map<String, dynamic> _payload(int tabType, int offset) {
    if (tabType == 2) {
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
    return {
      'code': 0,
      'data': {
        'tab_index': 0,
        'tab_item': [
          {
            'tab_type': tabType,
            'title': '分类',
            'next_offset': tabType == cursorlessTab ? 0 : offset + 1,
            'session_id': 'sess',
            'cell_data': [
              {
                'video_data': [
                  for (var i = 0; i < 6; i++)
                    {
                      'series_id_str': '${offset}_$i',
                      'series_title': '剧$offset-$i',
                      'series_cover': '',
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
    final tabType = int.tryParse(q['tab_type'] ?? '2') ?? 2;
    final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
    calls.add('$tabType@$offset');
    // 给并发留出窗口：真实网络下这个间隙足够第二次调用挤进来。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(_payload(tabType, offset)))),
      'application/json',
    );
  }
}


/// 固定返回一份 JSON 的 transport，用来单独验证 ApiClient 的认领/游标逻辑。
class _StaticTransport extends BackendTransport {
  _StaticTransport(this.payload) : super(port: 0);

  final Map<String, dynamic> payload;

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      'application/json',
    );
  }
}

/// 搜索 A 慢、搜索 B 快，用来验证「旧关键词的结果不能覆盖新关键词」。
class _SearchRaceFake extends BackendTransport {
  _SearchRaceFake() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    final params = Uri.splitQueryString(query ?? '');
    if (path.startsWith('/api/v1/search')) {
      final keyword = params['query'] ?? '';
      await Future<void>.delayed(
        keyword == 'A'
            ? const Duration(milliseconds: 120)
            : const Duration(milliseconds: 10),
      );
      return _json({
        'code': 0,
        'data': {
          'search_tabs': [
            {
              'tab_type': 3,
              'next_offset': 10,
              'data': [
                {
                  'book_data': {'book_id': keyword, 'book_name': '结果$keyword'},
                },
              ],
            },
          ],
        },
      });
    }
    return _json({
      'code': 0,
      'data': {
        'tab_index': 0,
        'tab_item': [
          {
            'tab_type': 2,
            'next_offset': 10,
            'session_id': 'sess',
            'cell_data': [
              {
                'book_data': [
                  {'book_id': 'b1', 'book_name': '书1'},
                ],
              },
            ],
          },
        ],
      },
    });
  }

  BackendResponse _json(Map<String, dynamic> payload) => BackendResponse(
    200,
    Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    'application/json',
  );
}

Future<(ProviderContainer, RecommendFeedController, _SlowFake)> _feedFor(
  RecommendCategory category,
) async {
  final fake = _SlowFake();
  final container = ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
  );
  final provider = recommendFeedProvider(category);
  await container.read(provider.future);
  return (container, container.read(provider.notifier), fake);
}

void main() {
  group('分页状态字段', () {
    test('RecommendState.withLoadMoreError 保留 loadingMore', () {
      final state = FeedState<RecommendItem>.feed(items: const <RecommendItem>[])
          .withLoadingMore(true)
          .withLoadMoreError('boom');
      expect(state.loadingMore, isTrue, reason: '清错误不能把 loadingMore 清掉');
      expect(state.loadMoreError, 'boom');
    });
  });

  test('小说分类：并发 loadMore 只发一个请求', () async {
    final (container, notifier, fake) = await _feedFor(
      RecommendCategory.novel,
    );
    addTearDown(container.dispose);
    await Future.wait<void>([notifier.loadMore(), notifier.loadMore()]);
    expect(fake.calls, ['2@0', '2@1'], reason: '第二次并发调用必须被重入锁挡掉');
  });

  test('短剧分类：并发 loadMore 只发一个请求', () async {
    final (container, notifier, fake) = await _feedFor(RecommendCategory.drama);
    addTearDown(container.dispose);
    await Future.wait<void>([notifier.loadMore(), notifier.loadMore()]);
    expect(fake.calls, ['8@0', '8@1'], reason: '第二次并发调用必须被重入锁挡掉');
  });

  test('漫剧分类：真实上游没有游标，loadMore 不再发请求', () async {
    // 漫剧（tab_type=24）实测只回首页一屏、next_offset 恒为 0：不能像短剧那样
    // 造一个可翻页的假数据，否则测试会掩盖「漫剧翻不动」这个事实。
    final fake = _SlowFake(cursorlessTab: 24);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
    );
    addTearDown(container.dispose);
    final provider = recommendFeedProvider(RecommendCategory.anime);
    final state = await container.read(provider.future);
    expect(state.hasMore, isFalse);
    await container.read(provider.notifier).loadMore();
    expect(fake.calls, ['24@0'], reason: '没有游标就不该再翻页');
  });

  group('ApiClient 分类契约', () {
    test('videoFeed 认领 tab_type：上游答错分类时抛错', () async {
      final api = ApiClient(
        _StaticTransport({
          'code': 0,
          'data': {
            'tab_index': 0,
            'tab_item': [
              {
                'tab_type': 8,
                'title': '看剧',
                'next_offset': 0,
                'cell_data': <Object>[],
              },
            ],
          },
        }),
      );
      await expectLater(
        api.videoFeed(tabType: 24),
        throwsA(isA<ApiException>()),
        reason: '请求漫剧却回了短剧，不能当漫剧画',
      );
    });

    test('漫剧无游标：解析 pseries 卡片且 hasMore=false', () async {
      final api = ApiClient(
        _StaticTransport({
          'code': 0,
          'data': {
            'tab_index': 0,
            'tab_item': [
              {
                'tab_type': 24,
                'title': '漫剧',
                'next_offset': 0,
                'cell_data': [
                  {
                    'cell_data': [
                      {
                        'video_data': [
                          {
                            'pseries_id': 'a1',
                            'series_name': '漫剧A',
                            'episode_cnt': '12',
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        }),
      );
      final page = await api.videoFeed(tabType: 24);
      expect(page.items.single.id, 'a1');
      expect(page.hasMore, isFalse);
    });
  });

  test('搜索 A 未返回就提交 B：只保留 B 的结果', () async {
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(_SearchRaceFake())),
      ],
    );
    addTearDown(container.dispose);
    final provider = recommendFeedProvider(RecommendCategory.novel);
    await container.read(provider.future);

    container.read(searchQueryProvider.notifier).submit('A');
    container.read(provider); // 触发 build，让 A 的请求真正发出去
    await Future<void>.delayed(const Duration(milliseconds: 20));

    container.read(searchQueryProvider.notifier).submit('B');
    container.read(provider);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final state = container.read(provider).value!;
    expect(state.query, 'B', reason: '最终状态必须是最新关键词');
    expect(
      state.items.map((item) => item.id),
      ['B'],
      reason: 'A 的迟到结果必须被 generation 丢弃',
    );
  });
}
