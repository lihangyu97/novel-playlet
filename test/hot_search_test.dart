import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/hot_search.dart';

/// 热搜榜解析：字段取 472 热搜榜真实形态（2026-11-15 真机抓包），只对形状与
/// 错误处理做断言，不依赖网络。
void main() {
  group('HotSearch.fromPayload', () {
    test('reads title / hot value / badge from search_tag_data', () {
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {
            'cell_name': '番茄热搜榜',
            'search_tag_data': [
              {
                'tag_title': '神通者',
                'tag_attached': '183.8万热搜值',
                'display_tag': [
                  {'text': '巅峰榜'},
                ],
              },
              {
                'tag_title': '9.9高分的小说！！！！',
                'tag_attached': '110.2万热搜值',
                'display_tag': [
                  {'text': '热聊'},
                ],
              },
              {'tag_title': '传奇', 'tag_attached': '好故事相聚，热爱不散场'},
            ],
          },
        ],
      });

      expect(hot.words, ['神通者', '9.9高分的小说！！！！', '传奇']);
      expect(hot.entries.map((e) => e.hotValue), ['183.8万', '110.2万', '']);
      expect(hot.entries.map((e) => e.hotPrefix), ['', '', '']);
      expect(hot.entries.map((e) => e.badge?.text), ['巅峰榜', '热聊', null]);
      expect(hot.entries.map((e) => e.hotLabel), ['184w+', '110w+', '']);
    });

    test('reads 热搜值 with an editorial prefix (live 2026-11-15 shape)', () {
      // 真机实测：部分词条的 tag_attached 不是纯数字，而是「前缀·数字」，
      // 例如热门讨论·39054552热搜值。解析必须取末尾数字，不能整段丢弃。
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {'tag_title': '9.9高分的小说！！！！', 'tag_attached': '热门讨论·39054552热搜值'},
              {'tag_title': '神通者', 'tag_attached': '巅峰榜NO.3·5562896热搜值'},
              {'tag_title': '男人哪有火锅香，我吃火锅不烧心', 'tag_attached': '3048111热搜值'},
              {'tag_title': '绝区零', 'tag_attached': '最近上榜·595733热搜值'},
            ],
          },
        ],
      });

      expect(hot.entries.map((e) => e.hotValue), [
        '39054552',
        '5562896',
        '3048111',
        '595733',
      ]);
      expect(hot.entries.map((e) => e.hotPrefix), [
        '热门讨论·',
        '巅峰榜NO.3·',
        '',
        '最近上榜·',
      ]);
      expect(hot.entries.map((e) => e.hotLabel), [
        '热门讨论·3905w+',
        '巅峰榜NO.3·556w+',
        '305w+',
        '最近上榜·60w+',
      ]);
    });

    test('reads display_tag text and light/dark colors', () {
      // 真机形态：颜色是 #RRGGBBAA（业务色 + 透明度），解析后要转成 ARGB int。
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {
                'tag_title': '9.9高分的小说！！！！',
                'tag_attached': '热门讨论·39054552热搜值',
                'display_tag': [
                  {
                    'text': '热聊',
                    'text_gradient_color': {
                      'light': ['#FA6725'],
                      'dark': ['#CC561F'],
                    },
                    'bg_gradient_color': {
                      'light': ['#FA67251A'],
                      'dark': ['#CC561F33'],
                    },
                  },
                ],
              },
              {'tag_title': '龙族', 'tag_attached': '2021680热搜值'},
            ],
          },
        ],
      });

      final badge = hot.entries.first.badge!;
      expect(badge.text, '热聊');
      expect(badge.lightTextColors, [0xFFFA6725]);
      expect(badge.darkTextColors, [0xFFCC561F]);
      expect(badge.lightBackgroundColors, [0x1AFA6725]);
      expect(badge.darkBackgroundColors, [0x33CC561F]);
      expect(hot.entries.last.badge, isNull);
    });

    test('flattens cells, skips empty tags and duplicate words', () {
      final hot = HotSearch.fromPayload({
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {'tag_title': '重复', 'tag_attached': '10万热搜值'},
              {'tag_title': '', 'tag_attached': '20万热搜值'},
            ],
          },
          {'cell_name': '没有 tag 的 cell'},
          {
            'search_tag_data': [
              {'tag_title': '重复', 'tag_attached': '30万热搜值'},
              {'tag_title': '新词'},
            ],
          },
        ],
      });
      expect(hot.words, ['重复', '新词']);
      expect(hot.entries.first.hotValue, '10万');
    });

    test('malformed / failed payload yields an empty board', () {
      expect(HotSearch.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(HotSearch.fromPayload({'code': 0, 'data': 'x'}).isEmpty, isTrue);
      expect(HotSearch.fromPayload({'code': 103001}).isEmpty, isTrue);
      expect(HotSearch.empty.isEmpty, isTrue);
      expect(HotSearch.empty.isNotEmpty, isFalse);
    });
  });

  group('formatHotSearchValue', () {
    test('converts to w and rounds to an integer', () {
      expect(formatHotSearchValue('183.8万'), '184w+');
      expect(formatHotSearchValue('183.8万热搜值'), '184w+');
      expect(formatHotSearchValue('热门讨论·39054552热搜值'), '3905w+');
      expect(formatHotSearchValue('183.0万'), '183w+');
      expect(formatHotSearchValue('183万'), '183w+');
    });

    test('亿 / raw counts convert to w', () {
      expect(formatHotSearchValue('1.2亿'), '12000w+');
      expect(formatHotSearchValue('123456'), '12w+');
      expect(formatHotSearchValue('9999'), '1w+');
    });

    test('non-numeric editorial text has no hot value', () {
      expect(formatHotSearchValue(''), '');
      expect(formatHotSearchValue('好故事相聚，热爱不散场'), '');
      expect(formatHotSearchValue('0'), '');
    });
  });
}
