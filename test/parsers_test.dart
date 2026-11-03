import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/book_detail.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/data/models/novel_item.dart';

/// 数据层解析测试：只用 JSON，不联网、不启内核。
///
/// 上游字段类型不稳定（数值是字符串、列表是单对象、id 会被截断），这类
/// 兼容逻辑只有单测兜得住，页面测试覆盖不到。
void main() {
  group('NovelItem', () {
    test('从 book_data 对象取字段', () {
      final item = NovelItem.fromRaw({
        'cell_id': 'c1',
        'book_data': {
          'book_id': '7143038691944959011',
          'book_name': '测试小说',
          'thumb_url': 'https://example.com/a.jpg',
          'author': '某作者',
          'word_number': '1328318',
          'score': '9.3',
        },
      });
      expect(item.id, '7143038691944959011');
      expect(item.title, '测试小说');
      expect(item.author, '某作者');
      expect(item.wordCount, 1328318);
      expect(item.score, '9.3');
      expect(item.isValid, isTrue);
    });

    test('字段直挂卡片也能取到', () {
      final item = NovelItem.fromRaw({
        'book_id': 'b2',
        'title': '直挂标题',
        'cover_url': 'https://example.com/b.jpg',
      });
      expect(item.id, 'b2');
      expect(item.title, '直挂标题');
      expect(item.cover, 'https://example.com/b.jpg');
    });
  });

  group('parseNovelItems', () {
    test('推荐流 cell_data 里层层嵌套的卡片都能捞出来且去重', () {
      final payload = {
        'code': 0,
        'data': {
          'next_offset': 10,
          'session_id': 'sess-1',
          'cell_data': [
            {
              'cell_name': '猜你喜欢',
              'items': [
                {
                  'book_data': {
                    'book_id': 'a1',
                    'book_name': '书A',
                    'thumb_url': 'https://example.com/a.jpg',
                  },
                },
                {
                  'book_data': {
                    'book_id': 'a1',
                    'book_name': '书A',
                  },
                },
                {
                  'book_data': [
                    {'book_id': 'a2', 'book_name': '书B'},
                  ],
                },
              ],
            },
          ],
        },
      };
      final items = parseNovelItems(payload);
      expect(items.map((item) => item.id), ['a1', 'a2']);
      expect(items.map((item) => item.title), ['书A', '书B']);
    });

    test('短剧/漫画卡片不会被当成小说', () {
      final payload = {
        'data': {
          'cell_data': [
            {
              'video_data': [
                {'video_id': 'v1', 'series_title': '短剧'},
              ],
            },
            {
              'book_data': {'book_id': 'b1', 'book_name': '小说'},
            },
          ],
        },
      };
      final items = parseNovelItems(payload);
      expect(items.map((item) => item.id), ['b1']);
    });
  });

  group('parseSearchNovels', () {
    test('只取书籍 tab，忽略其它 tab', () {
      final payload = {
        'code': 0,
        'data': {
          'search_tabs': [
            {
              'tab_type': 1,
              'title': '综合',
              'data': [
                {
                  'book_data': {'book_id': 'b1', 'book_name': '小说一'},
                },
              ],
            },
            {
              'tab_type': 8,
              'title': '漫画',
              'data': [
                {'manga_id': 'm1', 'book_name': '漫画'},
              ],
            },
          ],
        },
      };
      final items = parseSearchNovels(payload);
      expect(items.map((item) => item.id), ['b1']);
    });
  });

  group('BookDetail', () {
    test('数值字段是字符串也要能读', () {
      final detail = BookDetail.fromPayload({
        'code': 0,
        'data': {
          'book_id': 'b1',
          'book_name': '测试书',
          'author_info': {'name': '作者甲', 'id': '2_1'},
          'abstract': '简介内容',
          'word_number': '1328318',
          'creation_status': '1',
          'content_chapter_number': '120',
          'read_count': '1.2万人在读',
          'score': '9.3',
          'tags': ['玄幻', '热血'],
          'detail_page_thumb_url': 'https://example.com/d.jpg',
        },
      });
      expect(detail.title, '测试书');
      expect(detail.author, '作者甲');
      expect(detail.wordNumber, 1328318);
      expect(detail.wordLabel, '132.8万字');
      expect(detail.statusLabel, '已完结');
      expect(detail.serialCount, 120);
      expect(detail.tags, ['玄幻', '热血']);
      expect(detail.metaParts.length, 3);
    });
  });

  group('parseDirectory', () {
    test('item_data_list 摊平且保留卷名', () {
      final payload = {
        'code': 0,
        'data': {
          'item_data_list': [
            {'item_id': 'c1', 'title': '第一章', 'volume_name': '第一卷'},
            {'item_id': 'c2', 'title': '第二章', 'volume_name': '第一卷'},
            {'title': '占位（没有 id，应被丢弃）'},
          ],
        },
      };
      final chapters = parseDirectory(payload);
      expect(chapters.map((chapter) => chapter.id), ['c1', 'c2']);
      expect(chapters.map((chapter) => chapter.index), [0, 1]);
      expect(chapters.first.volumeName, '第一卷');
    });
  });

  group('正文 HTML 清洗', () {
    test('p/br/img 与实体', () {
      const html =
          '<p>第一段&nbsp;内容</p><p>第二段<br>换行</p>'
          '<div><img src="x.png">第三段</div><script>bad()</script>';
      final paragraphs = htmlToParagraphs(html);
      expect(paragraphs, ['第一段 内容', '第二段', '换行', '第三段']);
    });

    test('p 里的裸换行也要切成独立段落（否则后续行没有首行缩进）', () {
      const html = '<p>第一行\n第二行</p><p>第三段</p>';
      expect(htmlToParagraphs(html), ['第一行', '第二行', '第三段']);
    });

    test('正文响应必须显式标记已解密', () {
      expect(
        () => parseChapterContent(
          {
            'code': 0,
            'data': {'content': '<p>abc</p>', 'content_decrypted': false},
          },
          chapterId: 'c1',
        ),
        throwsA(isA<ApiException>()),
      );
    });

    test('解密标记为 true 时解析成段落', () {
      final content = parseChapterContent(
        {
          'code': 0,
          'data': {
            'content': '<p>正文一</p><p>正文二</p>',
            'content_decrypted': true,
          },
        },
        chapterId: 'c1',
        title: '第一章',
      );
      expect(content.title, '第一章');
      expect(content.paragraphs, ['正文一', '正文二']);
      expect(content.isEmpty, isFalse);
    });
  });

  group('信封', () {
    test('业务错误抛 ApiException 并带 message', () {
      expect(
        () => unwrapEnvelope({'code': 101116, 'message': '设备异常'}),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            '设备异常',
          ),
        ),
      );
    });

    test('返回下一页游标递增才算有下一页', () {
      final page = NovelFeedPage(items: const [], nextOffset: 10);
      expect(page.hasMore, isTrue);
      expect(const NovelFeedPage(items: []).hasMore, isFalse);
      expect(Chapter.fromRaw({'item_id': 'x'}).id, 'x');
    });
  });
}
