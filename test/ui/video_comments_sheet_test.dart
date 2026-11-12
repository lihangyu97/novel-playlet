import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/features/video/widgets/video_comments_sheet.dart';

/// 短剧评论弹层：剧评（cursor 翻页首屏）、本集评论、空态与失败重试。

class _SheetTransport extends BackendTransport {
  _SheetTransport(this.respond) : super(port: 0);

  final Map<String, dynamic> Function(String path, Map<String, String> query)
  respond;
  final calls = <String>[];
  final statuses = <int>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    final params = Uri.splitQueryString(query ?? '');
    calls.add('$path?${query ?? ''}');
    final status = statuses.isNotEmpty ? statuses.removeAt(0) : 200;
    return BackendResponse(
      status,
      Uint8List.fromList(utf8.encode(jsonEncode(respond(path, params)))),
      'application/json',
    );
  }
}

Map<String, dynamic> _commentEntry(
  String id,
  String text, {
  String user = '读者',
  int digg = 0,
}) => {
  'comment': {
    'comment_id': id,
    'common': {
      'content': {'text': text},
      'user_info': {
        'base_info': {'user_name': user},
      },
      'create_timestamp': 1700000000,
    },
    'stat': {'digg_count': '$digg'},
  },
};

Map<String, dynamic> _page(
  List<Map<String, dynamic>> comments, {
  int total = 0,
  String cursor = '',
  bool hasMore = false,
}) => {
  'code': 0,
  'data': {
    'data_list': comments,
    'common_list_info': {
      'total': total > 0 ? '$total' : '${comments.length}',
      'cursor': cursor,
      'has_more': hasMore,
    },
  },
};

Future<void> _pumpSheet(
  WidgetTester tester,
  _SheetTransport transport, {
  String vid = '',
  BookCommentPage? initialPage,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(transport))],
      child: MaterialApp(
        home: Scaffold(
          body: VideoCommentsSheet(
            seriesId: 'v1',
            vid: vid,
            initialPage: initialPage,
          ),
        ),
      ),
    ),
  );
  // 首屏是异步请求 + 可能有一帧 loading spinner，不能 pumpAndSettle。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {});

  testWidgets('剧评首屏：标题/计数/正文，请求 count=20 且不带 cursor', (tester) async {
    final transport = _SheetTransport(
      (path, query) => _page([
        _commentEntry('c1', '这部剧节奏很好', user: '小明', digg: 12),
        _commentEntry('c2', '第二集开始上头', user: '小红'),
      ], total: 42),
    );
    await _pumpSheet(tester, transport);

    expect(find.text('剧评'), findsOneWidget);
    expect(find.text('共 42 条'), findsOneWidget);
    expect(find.text('这部剧节奏很好'), findsOneWidget);
    expect(find.text('第二集开始上头'), findsOneWidget);
    final query = Uri.splitQueryString(
      transport.calls.single.substring(transport.calls.single.indexOf('?') + 1),
    );
    expect(query['count'], '20');
    expect(query.containsKey('cursor'), isFalse);
    // 短剧评论没有评分，弹层里不应出现空星。
    expect(find.byIcon(Icons.star_border_rounded), findsNothing);
  });

  testWidgets('本集评论：按 vid 走 hot-comments，标题与成功/空态文案不同', (tester) async {
    final transport = _SheetTransport(
      (path, query) => _page([_commentEntry('e1', '这集打戏不错')], total: 7),
    );
    await _pumpSheet(tester, transport, vid: 'e1');

    expect(find.text('本集评论'), findsOneWidget);
    expect(find.text('共 7 条'), findsOneWidget);
    expect(find.text('这集打戏不错'), findsOneWidget);
    expect(
      transport.calls.single,
      startsWith('/api/v1/series/v1/hot-comments?'),
    );
    expect(
      Uri.splitQueryString(
        transport.calls.single.substring(
          transport.calls.single.indexOf('?') + 1,
        ),
      )['vid'],
      'e1',
    );
  });

  testWidgets('空态：剧评与本集评论用不同文案', (tester) async {
    await _pumpSheet(tester, _SheetTransport((_, _) => _page([])));
    expect(find.text('还没有剧评'), findsOneWidget);
  });

  testWidgets('空态：本集评论', (tester) async {
    await _pumpSheet(tester, _SheetTransport((_, _) => _page([])), vid: 'e1');
    expect(find.text('本集还没有评论'), findsOneWidget);
  });

  testWidgets('首屏失败显示重试，重试成功后回到列表', (tester) async {
    final transport = _SheetTransport(
      (path, query) => _page([_commentEntry('c1', '重试后出现')], total: 1),
    )..statuses.addAll([500]);
    await _pumpSheet(tester, transport);

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('重试后出现'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('重试后出现'), findsOneWidget);
    expect(transport.calls, hasLength(2));
  });

  testWidgets('传入 initialPage 时先铺列表，不再二次请求首屏', (tester) async {
    final initial = BookCommentPage(
      comments: const [BookComment(id: 'c1', text: '详情页已经拿到的第一条')],
      totalCount: 3,
      hasMore: false,
    );
    final transport = _SheetTransport((_, _) => _page([]));
    await _pumpSheet(tester, transport, initialPage: initial);

    expect(find.text('详情页已经拿到的第一条'), findsOneWidget);
    expect(find.text('共 3 条'), findsOneWidget);
    expect(transport.calls, isEmpty, reason: '初始页已含数据，不应再打接口');
  });

  testWidgets('剧评滚到底用 cursor 拉下一页，并按 id 去重', (tester) async {
    final transport = _SheetTransport((path, query) {
      if (query['cursor'] == 'p2') {
        return _page([
          _commentEntry('c20', '第二页第一条'),
          _commentEntry('c3', '第二页第二条'),
        ], total: 30);
      }
      return _page(
        [
          for (var i = 0; i < 20; i++)
            _commentEntry('c$i', '第 $i 条评论，内容足够长让列表能滚动起来'),
          _commentEntry('c3', '第二页第二条'),
        ],
        total: 30,
        cursor: 'p2',
        hasMore: true,
      );
    });
    await _pumpSheet(tester, transport);

    expect(transport.calls, hasLength(1));
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      transport.calls.any((call) => call.contains('cursor=p2')),
      isTrue,
      reason: '滚动到底应带 cursor 拉下一页',
    );
    expect(find.text('第二页第一条'), findsOneWidget);
    // c3 两页都返回了，列表里只能出现一次。
    expect(find.text('第二页第二条'), findsOneWidget);
  });
}
