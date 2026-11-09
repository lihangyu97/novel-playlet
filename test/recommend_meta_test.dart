import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/json_utils.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/data/parsers/video_parsers.dart';

/// 推荐卡元信息的数据层契约：用 2026-11-08 真机抓包的真实字段形态锁住
/// `recommend_reason_list` / `rank_score` / `rec_text` 的解析（见
/// docs/implementation.md 推荐链路）。
void main() {
  group('firstReasonText：两种上游形态', () {
    test('小说：数组元素取 content（真实样本：巅峰榜 / 老书虫在看 / 细糠）', () {
      expect(
        firstReasonText([
          {'content': '巅峰榜No.3', 'can_click': true},
          {'content': '19个老书虫在看'},
        ]),
        '巅峰榜No.3',
      );
    });

    test('短剧：JSON 串优先 rec_tags[0].content', () {
      expect(
        firstReasonText(
          '{"tag_info":{"text":""},"rec_tags":[{"content":"系列剧·40万人在追",'
          '"recommend_reason":"系列剧·xx"},{"content":"27万人收藏"}]}',
        ),
        '系列剧·40万人在追',
      );
    });

    test('漫剧：没有 rec_tags 时用 tag_info.text（上新/热门）', () {
      expect(
        firstReasonText(
          '{"tag_info":{"text":"上新","bg_color":["#00B876"]},'
          '"sub_title_list":[{"content":"剧情"},{"content":"149集"}]}',
        ),
        '上新',
      );
    });

    test('空值 / 0 / 非法 JSON 兜底', () {
      expect(firstReasonText(null), '');
      expect(firstReasonText(''), '');
      expect(firstReasonText('0'), '');
      expect(firstReasonText('{半截'), '{半截');
    });
  });

  group('列表模型解析真实字段', () {
    test('小说：recommend_reason_list / rank_score / score', () {
      final item = NovelItem.fromRaw({
        'book_id': '1',
        'book_name': '书名',
        'author': '道不易',
        'recommend_reason_list': [
          {'content': '巅峰榜No.3', 'can_click': true},
        ],
        'rank_score': '8479万热度',
        'score': '9.3',
        'color_dominate': '#201818',
      });
      expect(item.recommendReason, '巅峰榜No.3');
      expect(item.rankScore, '8479万热度');
      expect(item.score, '9.3');
      expect(item.colorDominate, '#201818');
    });

    test('小说：只带 back_color_dominate 时退用它当封面占位色', () {
      final item = NovelItem.fromRaw({
        'book_id': '2',
        'book_name': '书名2',
        'back_color_dominate': '#131F37',
      });
      expect(item.colorDominate, '#131F37');
    });

    test('短剧：JSON 串理由 + rec_text 热度 + score', () {
      final items = parseVideoSeries({
        'data': {
          'tab_item': [
            {
              'tab_type': 8,
              'cell_data': [
                {
                  'cell_data': [
                    {
                      'video_data': [
                        {
                          'series_id': 'v1',
                          'title': '剧名',
                          'episode_cnt': 40,
                          'score': '8.2',
                          'recommend_reason_list':
                              '{"tag_info":{"text":"上新"},'
                              '"rec_tags":[{"content":"系列剧·40万人在追"}]}',
                          'rec_text': '4691万热度',
                          'show_rec_text': true,
                          'color_dominate': '#2F1B36',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      });
      expect(items, hasLength(1));
      expect(items.first.recommendReason, '系列剧·40万人在追');
      expect(items.first.rankScore, '4691万热度');
      expect(items.first.score, '8.2');
      expect(items.first.colorDominate, '#2F1B36');
    });

    test('短剧：show_rec_text=false 时不把 rec_text 当热度', () {
      final items = parseVideoSeries({
        'data': {
          'video_data': [
            {
              'series_id': 'v2',
              'title': '剧名2',
              'rec_text': '9999万热度',
              'show_rec_text': false,
            },
          ],
        },
      });
      expect(items, hasLength(1));
      expect(items.first.rankScore, '');
    });
  });
}
