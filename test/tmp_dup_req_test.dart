import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/video/video_page.dart';

class _Fake extends BackendTransport {
  _Fake(this.video) : super(port: 0);
  final bool video;
  final calls = <String>[];

  Map<String, dynamic> _page(String offset) {
    final n = int.tryParse(offset) ?? 0;
    if (video) {
      return {
        'code': 0,
        'data': {
          'tab_index': 0,
          'tab_item': [
            {
              'tab_type': 8,
              'title': '看剧',
              'next_offset': n + 1,
              'session_id': 'sess',
              'cell_data': [
                {
                  'video_data': [
                    for (var i = 0; i < 6; i++)
                      {
                        'series_id': '${n}_$i',
                        'title': '剧$n-$i',
                        'cover': '',
                        'episode_cnt': 100,
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
            'next_offset': n + 1,
            'session_id': 'sess',
            'cell_data': [
              {
                'book_data': [
                  for (var i = 0; i < 6; i++)
                    {
                      'book_id': 'b${n}_$i',
                      'book_name': '书$n-$i',
                      'author': '作者',
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
    calls.add('${q['tab_type'] ?? '-'}@${q['offset'] ?? '-'}');
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(_page(q['offset'] ?? '0')))),
      'application/json',
    );
  }
}

Future<void> run(WidgetTester tester, Widget page, bool video) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final fake = _Fake(video);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(fake))],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 模拟用户连续上滑 3 次
  for (var i = 0; i < 3; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
  }
  // ignore: avoid_print
  print('[${video ? '短剧' : '小说'}] 请求序列=${fake.calls}');
}
void main() {
  testWidgets('短剧翻页请求去重', (tester) async {
    await run(tester, const VideoPage(), true);
  });
  testWidgets('小说翻页请求去重', (tester) async {
    await run(tester, const RecommendPage(), false);
  });
}
