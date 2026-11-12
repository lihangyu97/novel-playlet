import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/json_utils.dart';

/// 短剧评论接口契约：Dart 侧新增的 `seriesComments` / `episodeComments` 只会
/// 拼路由和查询参数，解析复用 `BookCommentPage.fromCommentListPayload`。
///
/// Rust 内核早已有这两条读路由（`/series/:id/comments` 与
/// `/series/:id/hot-comments`），这里锁住 Dart 侧不发错路径/参数。
class _FakeTransport extends BackendTransport {
  _FakeTransport(this.payload) : super(port: 0);

  Map<String, dynamic> payload;
  int status = 200;
  final calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add('$method $path?${query ?? ''}');
    return BackendResponse(
      status,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      'application/json',
    );
  }
}

Map<String, dynamic> _commentPayload({
  int total = 2,
  String cursor = '',
  bool hasMore = false,
}) => {
  'code': 0,
  'data': {
    'data_list': [
      {
        'comment': {
          'comment_id': 'c1',
          'common': {
            'content': {'text': '这部剧节奏很好'},
            'user_info': {
              'base_info': {'user_name': '小明'},
            },
            'create_timestamp': 1700000000,
          },
          'stat': {'digg_count': '12', 'reply_count': '2'},
        },
      },
      {
        'comment': {
          'comment_id': 'c2',
          'common': {
            'content': {'text': '第二集开始上头'},
            'user_info': {
              'base_info': {'user_name': '小红'},
            },
          },
          'stat': {'digg_count': '3'},
        },
      },
    ],
    'common_list_info': {
      'total': '$total',
      'cursor': cursor,
      'has_more': hasMore,
    },
  },
};

void main() {
  group('seriesComments（整部剧剧评）', () {
    test('拼对路由与查询参数，并解析 data_list + common_list_info', () async {
      final transport = _FakeTransport(
        _commentPayload(total: 42, cursor: 'next-1', hasMore: true),
      );
      final api = ApiClient(transport);

      final page = await api.seriesComments('v1', count: 20);

      expect(transport.calls, hasLength(1));
      expect(
        transport.calls.single,
        startsWith('GET /api/v1/series/v1/comments?'),
      );
      final query = Uri.splitQueryString(
        transport.calls.single.substring(
          transport.calls.single.indexOf('?') + 1,
        ),
      );
      expect(query['count'], '20');
      expect(query['sort'], '1');
      expect(query.containsKey('cursor'), isFalse, reason: '首屏不带 cursor');

      expect(page.comments, hasLength(2));
      expect(page.comments.first.id, 'c1');
      expect(page.comments.first.text, '这部剧节奏很好');
      expect(page.comments.first.userName, '小明');
      expect(page.comments.first.diggCount, 12);
      expect(page.comments.first.createdAt, isNotNull);
      expect(page.totalCount, 42);
      expect(page.cursor, 'next-1');
      expect(page.hasMore, isTrue);
    });

    test('翻页时把 cursor 原样带上', () async {
      final transport = _FakeTransport(_commentPayload());
      final api = ApiClient(transport);

      await api.seriesComments('v1', count: 20, cursor: 'cur-2');

      final query = Uri.splitQueryString(
        transport.calls.single.substring(
          transport.calls.single.indexOf('?') + 1,
        ),
      );
      expect(query['cursor'], 'cur-2');
    });

    test('seriesId 为空时直接返回空页，不发请求', () async {
      final transport = _FakeTransport(_commentPayload());
      final api = ApiClient(transport);

      final page = await api.seriesComments('');

      expect(page.isEmpty, isTrue);
      expect(transport.calls, isEmpty);
    });

    test('上游业务失败码按空页处理，不把详情页打成错误态', () async {
      final transport = _FakeTransport({'code': 103001, 'data': {}});
      final api = ApiClient(transport);

      final page = await api.seriesComments('v1');

      expect(page.isEmpty, isTrue);
      expect(page.totalCount, 0);
    });

    test('HTTP 5xx 仍抛 ApiException，交给调用方决定是否静默', () async {
      final transport = _FakeTransport({'message': 'boom'})..status = 500;
      final api = ApiClient(transport);

      await expectLater(api.seriesComments('v1'), throwsA(isA<ApiException>()));
    });
  });

  group('episodeComments（某一集评论）', () {
    test('拼对 hot-comments 路由与 vid / server_channel', () async {
      final transport = _FakeTransport(_commentPayload(total: 7));
      final api = ApiClient(transport);

      final page = await api.episodeComments('v1', 'e1');

      expect(
        transport.calls.single,
        startsWith('GET /api/v1/series/v1/hot-comments?'),
      );
      final query = Uri.splitQueryString(
        transport.calls.single.substring(
          transport.calls.single.indexOf('?') + 1,
        ),
      );
      expect(query['vid'], 'e1');
      expect(query['server_channel'], '17');
      expect(page.comments, hasLength(2));
      expect(page.totalCount, 7);
    });

    test('vid 为空时不发请求（否则上游会静默退回剧级评论）', () async {
      final transport = _FakeTransport(_commentPayload());
      final api = ApiClient(transport);

      final page = await api.episodeComments('v1', '');

      expect(page.isEmpty, isTrue);
      expect(transport.calls, isEmpty, reason: '缺 vid 必须直接短路，不能退化成剧评');
    });
  });
}
