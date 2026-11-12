import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/book_comment.dart';
import 'package:novel_playlet/data/models/chapter.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/data/models/chapter_ideas.dart';
import 'package:novel_playlet/data/models/comment_image.dart';
import 'package:novel_playlet/data/models/comment_reply.dart';

/// 评论/段评响应形状：与 fqapp 实机验证过的 payload 对齐。
void main() {
  group('ChapterIdeas', () {
    Map<String, dynamic> payload({Object? code = 0}) => {
      'code': code,
      'data': {
        'item_version': '',
        'data': {
          '0': {
            'bubble_data': {
              '1': {'channel': 0, 'count': 287},
            },
            'count': 287,
            'infos': <dynamic>[],
            'is_author_comment': false,
            'user_count': 0,
          },
          '28': {
            'bubble_data': {
              '1': {'channel': 0, 'count': 4},
            },
            'count': 4,
            'infos': [
              {'comment_id': 'c1'},
              {'comment_id': 'c2'},
            ],
            'is_author_comment': true,
            'user_count': 3,
          },
          '3': {'bubble_data': {}, 'count': 0, 'infos': <dynamic>[]},
          '10000': {'bubble_data': {}, 'count': 9, 'infos': <dynamic>[]},
        },
      },
    };

    test('按段落 id 解析计数、排序并合并章末桶', () {
      final ideas = ChapterIdeas.fromPayload(payload());
      expect(ideas.paragraphs.map((p) => p.paraIndex), [0, 3, 28, 10000]);
      expect(ideas.forParagraph(28)?.count, 4);
      expect(ideas.forParagraph(28)?.commentIds, ['c1', 'c2']);
      expect(ideas.forParagraph(28)?.isAuthor, isTrue);
      expect(ideas.forParagraph(28)?.userCount, 3);
      expect(ideas.total, 287 + 4 + 9);
      expect(ideas.chapterEndParaIndex, 10000);
      expect(ideas.bubbleCounts.keys, [0, 28, 10000], reason: 'count=0 的段不画气泡');
      expect(ideas.withIdeas, hasLength(3));
    });

    test('不可用 code 当空而不是报错', () {
      expect(ChapterIdeas.fromPayload(payload(code: 103001)).isEmpty, isTrue);
      expect(ChapterIdeas.fromPayload(payload(code: 1301008)).isEmpty, isTrue);
    });
  });

  group('BookCommentPage', () {
    test('段评正文：嵌套 comment/common/stat 归一化', () {
      final page = BookCommentPage.fromCommentListPayload({
        'code': 0,
        'data': {
          'common_list_info': {
            'cursor': '{"offset":20}',
            'has_more': true,
            'total': 12,
          },
          'data_list': [
            {
              'comment': {
                'comment_id': '7580',
                'common': {
                  'content': {'text': '这段写得好'},
                  'create_timestamp': 1756000000,
                  'user_info': {
                    'base_info': {'user_name': '读者甲', 'user_avatar': 'a.jpg'},
                  },
                },
                'stat': {'digg_count': 7, 'reply_count': 2},
              },
              'stat': {'digg_count': 99},
              'data_type': 0,
            },
            {
              'comment': {
                'comment_id': 'empty',
                'common': {
                  'content': {'text': ''},
                },
              },
            },
          ],
        },
      });
      expect(page.comments, hasLength(1), reason: '空正文不入列表');
      final comment = page.comments.single;
      expect(comment.id, '7580');
      expect(comment.text, '这段写得好');
      expect(comment.userName, '读者甲');
      expect(comment.diggCount, 7, reason: '优先取 comment.stat');
      expect(comment.replyCount, 2);
      expect(page.totalCount, 12);
      expect(page.hasMore, isTrue);
      expect(page.cursor, isNotEmpty);
    });

    test('旧书评：评分/统计/文案', () {
      final page = BookCommentPage.fromLegacyPayload({
        'code': 0,
        'data': {
          'comment_cnt': 6530,
          'context': '2.6万人点评',
          'has_more': true,
          'next_offset': 10,
          'comment': [
            {
              'comment_id': 'r1',
              'text': '好看',
              'score': 9,
              'digg_count': 3,
              'reply_count': 1,
              'read_duration': 3600,
              'create_timestamp': 1756000000,
              'user_info': {'user_name': '读者乙', 'is_author': false},
            },
          ],
        },
      });
      expect(page.comments.single.score, 9);
      expect(page.comments.single.stars, 4.5);
      expect(page.comments.single.readSeconds, 3600);
      expect(page.totalCount, 6530);
      expect(page.context, '2.6万人点评');
      expect(page.nextOffset, 10);
      expect(page.hasMore, isTrue);
    });
  });

  group('CommentReplyPage', () {
    test('Common 大写容器与统计', () {
      final page = CommentReplyPage.fromPayload({
        'code': 0,
        'data': {
          'reply_list': [
            {
              'reply_id': 'p1',
              'Common': {
                'content': {'text': '回复内容'},
                'create_timestamp': 1756000000,
                'user_info': {
                  'base_info': {'user_name': '读者丙'},
                },
              },
              'stat': {'digg_count': 1},
            },
          ],
          'common_list_info': {'total': 3, 'has_more': false, 'cursor': '20'},
        },
      });
      expect(page.replies.single.text, '回复内容');
      expect(page.replies.single.userName, '读者丙');
      expect(page.totalCount, 3);
      expect(page.hasMore, isFalse);
    });
  });

  group('正文段落锚点', () {
    ChapterContent parse(String html, {String title = ''}) =>
        parseChapterContent(
          {
            'code': 0,
            'data': {'content_decrypted': true, 'content': html},
          },
          chapterId: 'c1',
          title: title,
        );

    test('保留 <p idx> 锚点', () {
      final content = parse(
        '<header><div class="tt-title">第1章 标题</div></header>'
        '<article><p idx="0">第一段</p><p idx="1">第二段</p></article>',
        title: '第1章 标题',
      );
      expect(content.paragraphs, ['第一段', '第二段']);
      expect(content.paraIndices, [0, 1]);
      expect(content.paraIndexAt(1), 1);
      expect(content.paraIndexAt(9), isNull);
    });

    test('标题段没有 idx，裁掉标题时锚点同步裁掉', () {
      final content = parse('<p>第1章 标题</p><p idx="7">正文</p>', title: '第1章 标题');
      expect(content.paragraphs, ['正文']);
      expect(content.paraIndices, [7]);
    });

    test('一段被换行拆开时只有第一段拿 id（与官方口径一致）', () {
      final content = parse('<p idx="2">甲<br>乙</p>');
      expect(content.paragraphs, ['甲', '乙']);
      expect(content.paraIndices, [2, null]);
    });

    test('空段落被丢弃，不影响后续段落 id', () {
      final content = parse('<p idx="0"></p><p idx="1">有字</p>');
      expect(content.paragraphs, ['有字']);
      expect(content.paraIndices, [1]);
    });

    test('纯文本 / 无 idx 的源没有锚点', () {
      final content = parse('无标签正文');
      expect(content.paragraphs, ['无标签正文']);
      expect(content.paraIndices, [null]);
    });
  });

  group('Chapter.version', () {
    test('目录条目读取 version', () {
      final chapter = Chapter.fromRaw({
        'item_id': 'c1',
        'title': '第一章',
        'version': 'v-123',
      });
      expect(chapter.version, 'v-123');
    });

    test('缺 version 时为空', () {
      expect(Chapter.fromRaw({'item_id': 'c1', 'title': 'x'}).version, '');
    });
  });

  group('评论配图', () {
    test('解析 web_url / url / thumb_url，补齐协议并去重', () {
      final urls = parseCommentImages({
        'image_data': [
          {'web_url': '//p3.example.com/a.jpg?x=1&amp;y=2'},
          {'url': 'https://p3.example.com/b.jpg'},
          {'thumb_url': 'https://p3.example.com/b.jpg'},
          {'web_url': 'ftp://example.com/c.jpg'},
          {'web_url': ''},
        ],
      });
      expect(urls, [
        'https://p3.example.com/a.jpg?x=1&y=2',
        'https://p3.example.com/b.jpg',
      ]);
    });

    test('非 http(s) / 无 host / 空地址直接丢弃', () {
      expect(normalizeCommentImageUrl('  '), '');
      expect(normalizeCommentImageUrl('data:image/png;base64,xx'), '');
      expect(normalizeCommentImageUrl('https:///a.jpg'), '');
      expect(
        normalizeCommentImageUrl('http://a.example.com/x.jpg'),
        isNotEmpty,
      );
    });

    test('段评、旧书评、回复三条解析链路都带上配图', () {
      final commentPage = BookCommentPage.fromCommentListPayload({
        'code': 0,
        'data': {
          'data_list': [
            {
              'comment': {
                'comment_id': 'c1',
                'common': {
                  'content': {
                    'text': '配图段评',
                    'image_data_list': {
                      'image_data': [
                        {'web_url': 'https://img.example.com/1.jpg'},
                      ],
                    },
                  },
                },
              },
            },
          ],
        },
      });
      expect(commentPage.comments.single.imageUrls, [
        'https://img.example.com/1.jpg',
      ]);

      final legacyPage = BookCommentPage.fromLegacyPayload({
        'code': 0,
        'data': {
          'comment': [
            {
              'comment_id': 'r1',
              'text': '配图书评',
              'image_data_list': [
                {'web_url': 'https://img.example.com/2.jpg'},
              ],
            },
          ],
        },
      });
      expect(legacyPage.comments.single.imageUrls, [
        'https://img.example.com/2.jpg',
      ]);

      final replyPage = CommentReplyPage.fromPayload({
        'code': 0,
        'data': {
          'reply_list': [
            {
              'reply_id': 'p1',
              'Common': {
                'content': {
                  'text': '配图回复',
                  'image_data_list': {
                    'image_data': [
                      {'web_url': 'https://img.example.com/3.jpg'},
                    ],
                  },
                },
              },
            },
          ],
        },
      });
      expect(replyPage.replies.single.imageUrls, [
        'https://img.example.com/3.jpg',
      ]);
    });
  });
}
