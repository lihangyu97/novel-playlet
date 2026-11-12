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
                      {'book_id': 'b${offset}_$i', 'book_name': '书$offset-$i'},
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

  /// 漫剧翻页兜底：短剧搜索 tab 里的漫剧卡片 + 游标。
  Map<String, dynamic> _searchPayload(int tabType, int offset) => {
    'code': 0,
    'data': {
      'search_tabs': [
        {
          'tab_type': tabType,
          'title': '短剧',
          'has_more': true,
          'next_offset': offset + 1,
          'data': [
            for (var i = 0; i < 6; i++)
              {
                'video_data': {
                  'series_id_str': 'm${offset}_$i',
                  'series_title': '漫剧$offset-$i',
                  'tag_info': {'text': '漫剧'},
                },
              },
          ],
        },
      ],
    },
  };

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
    // 给并发留出窗口：真实网络下这个间隙足够第二次调用挤进来。
    // 翻页（offset>0）比首屏慢：这样"先把刷新响应写进 state、翻页响应后到"
    // 的顺序是确定的，P1-10 的旧 session 拼页 bug 才能被稳定测出来。
    await Future<void>.delayed(Duration(milliseconds: offset > 0 ? 120 : 40));
    if (path.startsWith('/api/v1/search')) {
      calls.add('search$tabType@$offset');
      return BackendResponse(
        200,
        Uint8List.fromList(
          utf8.encode(jsonEncode(_searchPayload(tabType, offset))),
        ),
        'application/json',
      );
    }
    calls.add('$tabType@$offset');
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
      final state = FeedState<RecommendItem>(items: const <RecommendItem>[])
          .withLoadingMore(true)
          .withLoadMoreError('boom');
      expect(state.loadingMore, isTrue, reason: '清错误不能把 loadingMore 清掉');
      expect(state.loadMoreError, 'boom');
    });
  });

  test('小说分类：并发 loadMore 只发一个请求', () async {
    final (container, notifier, fake) = await _feedFor(RecommendCategory.novel);
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

  test('漫剧分类：首页流无游标时改走搜索兜底翻页', () async {
    // 漫剧首页流（tab_type=24）没有游标，后续页靠短剧搜索 tab 里的漫剧卡片
    // （query=漫剧 + tab_type=11）接力；游标挂在搜索 tab 的 next_offset 上。
    final fake = _SlowFake(cursorlessTab: 24);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
    );
    addTearDown(container.dispose);
    final provider = recommendFeedProvider(RecommendCategory.anime);
    final notifier = container.read(provider.notifier);
    final state = await container.read(provider.future);
    expect(state.hasMore, isTrue, reason: '首页流没有游标，但搜索兜底还有下一页');

    await Future.wait<void>([notifier.loadMore(), notifier.loadMore()]);
    expect(fake.calls, [
      '24@0',
      'search11@0',
      'search11@1',
    ], reason: '翻页走搜索兜底，且并发调用只发一次');
  });

  group('refresh 与 loadMore 互斥', () {
    /// 刷新永远是 offset=0 的一页；断言列表回到"只有第一页 + 游标回到 1"。
    void expectFreshFirstPage(RecommendState state) {
      expect(state.items.map((item) => item.id), [
        'b0_0',
        'b0_1',
        'b0_2',
        'b0_3',
        'b0_4',
        'b0_5',
      ], reason: '刷新后的列表必须只有刷新返回的那一页（旧 session 的页要丢弃）');
      expect(state.nextOffset, 1, reason: '游标必须来自刷新那一页');
      expect(state.loadingMore, isFalse, reason: '被丢弃的翻页不能把 footer 卡在转圈');
    }

    test('refresh 期间 loadMore：不发翻页请求', () async {
      final (container, notifier, fake) = await _feedFor(
        RecommendCategory.novel,
      );
      addTearDown(container.dispose);
      final provider = recommendFeedProvider(RecommendCategory.novel);

      final refreshing = notifier.refresh();
      // 刷新在途：此时滚到底/补屏触发的翻页必须直接返回。
      await notifier.loadMore();
      await refreshing;

      expect(fake.calls, [
        '2@0',
        '2@0',
      ], reason: '首屏 + 一次刷新；刷新期间不允许发翻页（不能出现 2@1）');
      expectFreshFirstPage(container.read(provider).value!);
    });

    test('loadMore 进行中 refresh：迟到的翻页响应被丢弃', () async {
      final (container, notifier, fake) = await _feedFor(
        RecommendCategory.novel,
      );
      addTearDown(container.dispose);
      final provider = recommendFeedProvider(RecommendCategory.novel);

      final loading = notifier.loadMore();
      final refreshing = notifier.refresh();
      await Future.wait<void>([loading, refreshing]);

      // 翻页（offset=1）比刷新（offset=0）慢：刷新响应先到、翻页响应后到，
      // 正是旧实现会把旧 session 第二页拼进新列表的顺序。
      expect(fake.calls, ['2@0', '2@0', '2@1'], reason: '两份请求都发出去了');
      expectFreshFirstPage(container.read(provider).value!);
    });

    test('refresh 期间切分类：两个分类互不串数据', () async {
      final fake = _SlowFake();
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
      );
      addTearDown(container.dispose);
      final novel = recommendFeedProvider(RecommendCategory.novel);
      await container.read(novel.future);
      final novelNotifier = container.read(novel.notifier);

      final refreshing = novelNotifier.refresh();
      // 刷新在途时切到短剧：短剧是独立 provider，不该被小说的刷新波及。
      final drama = recommendFeedProvider(RecommendCategory.drama);
      final dramaState = await container.read(drama.future);
      await refreshing;

      expect(container.read(novel).value!.items.map((item) => item.id), [
        'b0_0',
        'b0_1',
        'b0_2',
        'b0_3',
        'b0_4',
        'b0_5',
      ], reason: '小说列表只包含小说分类的刷新结果');
      expect(dramaState.items.map((item) => item.id), [
        '0_0',
        '0_1',
        '0_2',
        '0_3',
        '0_4',
        '0_5',
      ], reason: '切过去的短剧列表保持自己的结果，不被小说的刷新覆盖');
      expect(fake.calls, [
        '2@0',
        '2@0',
        '8@0',
      ], reason: '小说 build + 刷新、短剧 build');
    });
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
}
