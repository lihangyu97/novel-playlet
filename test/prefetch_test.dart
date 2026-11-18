import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/rank.dart';
import 'package:novel_playlet/features/prefetch/app_prefetch.dart';
import 'package:novel_playlet/features/rank/rank_cache.dart';
import 'package:novel_playlet/features/rank/rank_providers.dart';
import 'package:novel_playlet/features/search/search_providers.dart';

class _PrefetchTransport extends BackendTransport {
  _PrefetchTransport() : super(port: 0);

  final calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add(path);
    if (path == '/api/v1/search/hot') {
      return _json({
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {'tag_title': '第一条热搜', 'tag_attached': '12.3万热搜值'},
            ],
          },
        ],
      });
    }
    if (path.startsWith('/api/v1/rank/')) {
      return _json({
        'code': 0,
        'data': {
          'cell_view': {
            'cell_data': [
              {
                'book_data': {'book_id': 'b1', 'book_name': '榜书1'},
              },
            ],
          },
        },
      });
    }
    return _json({'code': 0, 'data': <dynamic>[]});
  }

  BackendResponse _json(Map<String, dynamic> payload) => BackendResponse(
    200,
    Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    'application/json',
  );
}

const _catalog = RankCatalog(
  rankId: 'rank-1',
  tabs: [
    RankTab(name: '短剧榜', algo: 502),
    RankTab(name: '推荐榜', algo: 101),
  ],
);

void main() {
  test('预热一次拉热搜与默认榜第一页，重复调用不重复请求', () async {
    final transport = _PrefetchTransport();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(transport)),
        rankCatalogProvider.overrideWith((ref) async => _catalog),
      ],
    );
    addTearDown(container.dispose);

    await container.read(appPrefetchProvider).warm();
    await container.read(appPrefetchProvider).warm();

    expect(
      transport.calls.where((path) => path == '/api/v1/search/hot'),
      hasLength(1),
    );
    expect(
      transport.calls.where((path) => path == '/api/v1/rank/rank-1'),
      hasLength(1),
    );

    final hot = container.read(hotSearchProvider);
    expect(hot.entries.single.title, '第一条热搜');

    final cache = container.read(rankBoardCacheProvider);
    final key = const RankBoardCacheKey(
      rankId: 'rank-1',
      algo: 101,
      genreTab: 2,
    );
    final cached = cache.read(key);
    expect(cached, isNotNull);
    expect(cached!.board.entries.single.title, '榜书1');
    expect(
      cache.isFresh(cached, now: cached.fetchedAt.add(RankBoardCache.ttl)),
      isFalse,
    );
  });

  test('热搜 TTL 过期前不重复请求，force 才刷新', () async {
    final transport = _PrefetchTransport();
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(transport))],
    );
    addTearDown(container.dispose);

    final controller = container.read(hotSearchProvider.notifier);
    await controller.ensureFresh();
    final first = transport.calls
        .where((path) => path == '/api/v1/search/hot')
        .length;
    await controller.ensureFresh();
    expect(
      transport.calls.where((path) => path == '/api/v1/search/hot').length,
      first,
    );

    await controller.ensureFresh(force: true);
    expect(
      transport.calls.where((path) => path == '/api/v1/search/hot').length,
      first + 1,
    );
  });
}
