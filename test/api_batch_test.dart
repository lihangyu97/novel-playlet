import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';

/// `chaptersBatch` 的解析契约：批量接口里失败/未解密/空正文的章要"消失"，
/// 由离线下载器逐章回退单章接口（docs/offline-cache.md §5）。

class _FakeTransport extends BackendTransport {
  _FakeTransport(this.payload) : super(port: 0);

  final Map<String, dynamic> payload;
  final calls = <String>[];

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    calls.add('$path?${query ?? ''}');
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      'application/json',
    );
  }
}

List<Chapter> _chapters(int count) => [
  for (var i = 0; i < count; i++)
    Chapter(id: 'c$i', title: '第${i + 1}章', index: i),
];

void main() {
  group('parseBatchChapterContents', () {
    test('按 itemId 解析正文，标题与 HTML 清洗复用单章规则', () {
      final result = parseBatchChapterContents({
        'code': 0,
        'data': {
          'c1': {'content': '<p>第一章</p><p>正文一</p>', 'title': '第一章'},
          'c2': {'content': '<p>正文二</p>'},
        },
      });
      expect(result.keys, ['c1', 'c2']);
      expect(result['c1']!.title, '第一章');
      // 首段与标题重复时裁掉（与 parseChapterContent 一致）。
      expect(result['c1']!.paragraphs, ['正文一']);
      expect(result['c2']!.paragraphs, ['正文二']);
      expect(result['c2']!.title, isEmpty);
    });

    test('未解密 / 空正文 / 非对象条目不出现在结果里', () {
      final result = parseBatchChapterContents({
        'code': 0,
        'data': {
          'ok': {'content': '<p>正常</p>'},
          'encrypted': {'content': '<p>密文</p>', 'content_decrypted': false},
          'empty': {'content': ''},
          'blank': {'content': '<p>   </p>'},
          'notMap': 'oops',
        },
      });
      expect(result.keys, ['ok']);
    });

    test('整包业务失败返回空表（交给下载器逐章回退）', () {
      expect(
        parseBatchChapterContents({'success': false, 'error': 'boom'}),
        isEmpty,
      );
      expect(parseBatchChapterContents({'code': 101116}), isEmpty);
    });

    test('兼容 item_infos 嵌套形态', () {
      final result = parseBatchChapterContents({
        'code': 0,
        'data': {
          'item_infos': {
            'c9': {'content': '<p>九</p>', 'title': '第九章'},
          },
        },
      });
      expect(result['c9']!.paragraphs, ['九']);
    });
  });

  group('ApiClient.chaptersBatch', () {
    test('拼 item_ids 查询参数并解析返回', () async {
      final transport = _FakeTransport({
        'code': 0,
        'data': {
          'c0': {'content': '<p>零</p>'},
          'c1': {'content': '<p>一</p>'},
        },
      });
      final api = ApiClient(transport);
      final result = await api.chaptersBatch(_chapters(2));
      expect(result.length, 2);
      expect(result['c1']!.paragraphs, ['一']);
      expect(transport.calls, hasLength(1));
      expect(transport.calls.single, startsWith('/api/v1/chapters/batch?'));
      final query = Uri.splitQueryString(
        transport.calls.single.split('?').last,
      );
      expect(query['item_ids'], 'c0,c1');
    });

    test('空列表不发请求', () async {
      final transport = _FakeTransport({'code': 0, 'data': {}});
      final api = ApiClient(transport);
      expect(await api.chaptersBatch(const []), isEmpty);
      expect(transport.calls, isEmpty);
    });
  });
}
