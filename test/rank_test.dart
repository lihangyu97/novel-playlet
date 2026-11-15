import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/rank.dart';
import 'package:novel_playlet/features/rank/rank_providers.dart';
import 'package:novel_playlet/features/recommend/recommend_category.dart';

/// 榜单解析：目录/条目都取 2026-11-15 真机抓包形态（小说 book_data、短剧/
/// 漫剧 video_data），只断言字段与分页语义，不依赖网络。
Map<String, dynamic> _catalogue() => {
  'code': 0,
  'data': {
    'tab_item': [
      {
        'cell_data': [
          {
            'cell_id': 7098235271900037000,
            'cell_id_str': '7098235271900037133',
            'cell_alias': '根据实时阅读热度排行',
            'rank_with_category_data': {
              'rank_algo_list': [
                {'rank_name': '推荐榜', 'rank_algo': 101},
                {'rank_name': '完本榜', 'rank_algo': 100},
                {'rank_name': '巅峰榜', 'rank_algo': 200},
                {'rank_name': '新书榜', 'rank_algo': 108},
                {'rank_name': '漫剧榜', 'rank_algo': 550},
                {'rank_name': '短剧榜', 'rank_algo': 502},
              ],
              'sub_info_list': [
                {'info_id': 0, 'info_name': '全部'},
                {'info_id': 37, 'info_name': '穿越'},
              ],
            },
          },
        ],
      },
    ],
  },
};

Map<String, dynamic> _bookBoard({bool hasMore = true}) => {
  'code': 0,
  'data': {
    'has_more': hasMore,
    'next_offset': hasMore ? 30 : 0,
    'cell_view': {
      'cell_alias': '根据阅读热度排行',
      'cell_data': [
        for (var i = 0; i < 2; i++)
          {
            'book_data': [
              {
                'book_id': '764002426809640860$i',
                'book_name': '大唐：活着就变强？可我永生啊！$i',
                'author': '抱星明月居',
                'thumb_url': 'https://example.test/book$i.jpg',
                'abstract': '唐诗三百首，两百忆盛唐！',
                'pure_category_tags': '历史古代,开局',
                'category_schema':
                    '[{"name":"历史古代"},{"name":"穿越"},{"name":"历史"}]',
                'category': '“细糠”',
                'score': '8.4',
                'rank_score': '8869万热度',
                'creation_status': '1',
                'word_number': '1091323',
                'color_dominate': '#201818',
              },
            ],
          },
      ],
    },
  },
};

Map<String, dynamic> _videoBoard({bool hasMore = true, int count = 2}) => {
  'code': 0,
  'data': {
    'has_more': hasMore,
    'next_offset': 0,
    'cell_view': {
      'cell_alias': '榜单基于观看量、互动及个人兴趣排序',
      'cell_data': [
        for (var i = 0; i < count; i++)
          {
            'video_data': [
              {
                'series_id': '770611064007873640$i',
                'title': '搭讪之王$i',
                'cover': 'https://example.test/video$i.jpg',
                'video_desc': '大二学生陈北认清错误的恋爱关系后……',
                'score': '8.0',
                'episode_cnt': 320,
                'color_dominate': '#382820',
                'category_schema': '[{"name":"逆袭"},{"name":"奇幻脑洞"}]',
                'secondary_info_list': [
                  {'content': '逆袭', 'data_type': 3},
                  {'content': '全320集', 'data_type': 11},
                  {'content': '4225万热度', 'data_type': 2},
                ],
              },
            ],
          },
      ],
    },
  },
};

void main() {
  group('RankCatalog', () {
    test('reads rankId, tabs and genre_tab grouping', () {
      final catalog = RankCatalog.fromHomepagePayload(_catalogue());
      expect(catalog.rankId, '7098235271900037133');
      expect(catalog.alias, '根据实时阅读热度排行');
      expect(catalog.tabs.map((t) => t.name), [
        '推荐榜',
        '完本榜',
        '巅峰榜',
        '新书榜',
        '漫剧榜',
        '短剧榜',
      ]);
      expect(catalog.tabs.map((t) => t.algo), [101, 100, 200, 108, 550, 502]);
      expect(catalog.tabs.map((t) => t.genreTab), [2, 2, 2, 2, 5, 4]);
      expect(catalog.tabForAlgo(502)?.name, '短剧榜');
      expect(catalog.tabForGenreTab(5)?.name, '漫剧榜');
    });

    test('nested / malformed catalogue is handled', () {
      expect(
        RankCatalog.fromHomepagePayload({'code': 0, 'data': {}}).isEmpty,
        isTrue,
      );
      final nested = {
        'code': 0,
        'data': {
          'a': [
            {
              'cell_id_str': '42',
              'rank_with_category_data': {
                'rank_algo_list': [
                  {'rank_name': '巅峰榜', 'rank_algo': 200},
                ],
              },
            },
          ],
        },
      };
      expect(RankCatalog.fromHomepagePayload(nested).rankId, '42');
      expect(RankCatalog.fromHomepagePayload(nested).tabs.single.name, '巅峰榜');
    });
  });

  group('RankBoard books', () {
    test('reads book fields, tags, positions and next offset', () {
      final board = RankBoard.fromPayload(
        _bookBoard(),
        genreTab: 2,
        startAt: 1,
      );
      expect(board.hasMore, isTrue);
      expect(board.nextOffset, 30);
      expect(board.alias, '根据阅读热度排行');
      expect(board.entries.map((e) => e.position), [1, 2]);

      final entry = board.entries.first;
      expect(entry.kind, 'book');
      expect(entry.id, '7640024268096408600');
      expect(entry.title, '大唐：活着就变强？可我永生啊！0');
      expect(entry.author, '抱星明月居');
      expect(entry.cover, 'https://example.test/book0.jpg');
      expect(entry.category, '历史古代');
      expect(entry.tags, ['开局', '穿越', '历史']);
      expect(entry.scoreLabel, '8.4分');
      expect(entry.heat, '8869万热度');
      expect(entry.metaLabel, '抱星明月居 · 历史古代 · 8869万热度');
      expect(entry.toNovelItem().intro, '唐诗三百首，两百忆盛唐！');
    });

    test('a later page continues numbering', () {
      final board = RankBoard.fromPayload(
        _bookBoard(hasMore: false),
        genreTab: 2,
        offset: 30,
        startAt: 31,
      );
      expect(board.entries.map((e) => e.position), [31, 32]);
      expect(board.hasMore, isFalse);
      expect(board.nextOffset, isNull);
    });
  });

  group('RankBoard videos', () {
    test('reads video fields and maps genre_tab to manju kind', () {
      final board = RankBoard.fromPayload(_videoBoard(), genreTab: 5);
      expect(board.alias, '榜单基于观看量、互动及个人兴趣排序');
      final entry = board.entries.first;
      expect(entry.kind, 'manju');
      expect(entry.isManju, isTrue);
      expect(entry.id, '7706110640078736400');
      expect(entry.title, '搭讪之王0');
      expect(entry.category, '逆袭');
      expect(entry.tags, ['奇幻脑洞']);
      expect(entry.scoreLabel, '8.0分');
      expect(entry.heat, '4225万热度');
      expect(entry.metaLabel, '逆袭 · 全320集 · 4225万热度');
      expect(entry.toVideoSeries().episodeCount, 320);
      expect(entry.toVideoSeries().isManju, isTrue);
    });

    test('video board without next_offset advances by page size', () {
      final board = RankBoard.fromPayload(_videoBoard(count: 100), genreTab: 4);
      expect(board.entries, hasLength(100));
      expect(board.nextOffset, 100);
      expect(board.entries.first.kind, 'video');
    });
  });

  test('首页分类映射到推荐榜 / 短剧榜 / 漫剧榜', () {
    final catalog = RankCatalog.fromHomepagePayload(_catalogue());
    expect(rankTabForCategory(catalog, RecommendCategory.novel)?.algo, 101);
    expect(rankTabForCategory(catalog, RecommendCategory.drama)?.algo, 502);
    expect(rankTabForCategory(catalog, RecommendCategory.anime)?.algo, 550);
    expect(rankTabForCategory(catalog, RecommendCategory.drama)?.genreTab, 4);
    expect(rankTabForCategory(catalog, RecommendCategory.anime)?.genreTab, 5);
  });

  test('failed / malformed payload yields empty board', () {
    expect(
      RankBoard.fromPayload({'code': 103001}, genreTab: 2).isEmpty,
      isTrue,
    );
    expect(
      RankBoard.fromPayload({'code': 0, 'data': 'x'}, genreTab: 2).isEmpty,
      isTrue,
    );
    expect(RankBoard.empty.isEmpty, isTrue);
  });
}
