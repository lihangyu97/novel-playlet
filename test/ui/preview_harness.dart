import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/cache/app_cache.dart';
import 'package:novel_playlet/core/storage/offline/offline_book.dart';
import 'package:novel_playlet/core/storage/offline/offline_book_store.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';
import 'package:novel_playlet/core/storage/offline/offline_series.dart';
import 'package:novel_playlet/core/storage/offline/offline_series_store.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/cache/cache_providers.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/settings/settings_providers.dart';

/// UI 预览共享夹具：假 transport、内存章节缓存、预览字体、主题壳与 pump。
///
/// 目的不是断言像素，而是让 Lead 在没有模拟器/真机的环境里也能看到真实
/// 布局。更新基线：`flutter test --update-goldens test/ui/<页面>_test.dart`。
///
/// 顺带说明：封面 URL 故意留空，避免 widget 测试里真的发网络请求。
class FakePreviewTransport extends BackendTransport {
  FakePreviewTransport() : super(port: 0);

  /// 请求记录（`path?query`），用于断言取消搜索不会重新发请求。
  final calls = <String>[];

  /// 命中这些关键词的搜索返回 500（验证失败后换关键词/重试的 loading 态）。
  final failingQueries = <String>{};

  /// 这些章节的正文接口返回 500（验证「切章失败保留旧正文」）。
  final failingChapterIds = <String>{};

  /// 推荐流首页请求全部返回 500（验证首屏失败立即出错误页）。
  bool failRecommend = false;

  /// 详情接口返回的封面；非空时与列表封面不同，用来验证详情页不换图。
  String detailCoverUrl = '';

  /// 短剧详情接口返回的封面。
  String detailSeriesCoverUrl = '';

  /// 目录接口返回的章节/集数（短剧选集分组测试用）。
  int directoryChapterCount = 24;

  /// 列表封面 URL：默认空（golden 里用占位块），Hero 飞行测试才给真实 URL。
  String bookCoverUrl = '';
  String videoCoverUrl = '';

  /// 每次请求的延迟；只有需要观察中间 loading 态的单测才设置。
  Duration responseDelay = Duration.zero;

  /// 小说推荐流的卡片数；滚动保活测试需要多屏内容。
  int novelItemCount = 9;

  /// 搜索结果条数（默认 6；调大用于验证「搜索态滚动」等场景）。
  int searchItemCount = 6;

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
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    final keyword = params['query'] ?? '';
    final failed =
        (failRecommend && path.startsWith('/api/v1/recommend/homepage')) ||
        (path.startsWith('/api/v1/search') &&
            failingQueries.any(keyword.contains));
    if (failed) {
      return BackendResponse(
        500,
        Uint8List.fromList(utf8.encode(jsonEncode({'message': 'boom'}))),
        'application/json',
      );
    }
    // 单章失败：正文接口返回 500，目录/详情照常，用于验证「切章失败保留旧正文」。
    if (path.contains('/chapters/')) {
      final chapterId = Uri.decodeComponent(
        path.split('/chapters/')[1].split('/').first,
      );
      if (failingChapterIds.contains(chapterId)) {
        return BackendResponse(
          500,
          Uint8List.fromList(utf8.encode(jsonEncode({'message': 'boom'}))),
          'application/json',
        );
      }
    }
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(_payloadFor(path, query)))),
      'application/json',
    );
  }

  Map<String, dynamic> _payloadFor(String path, String? query) {
    final params = Uri.splitQueryString(query ?? '');
    if (path.startsWith('/api/v1/recommend/homepage')) {
      // 同一路由按 `tab_type` 分流：2 = 小说、8 = 短剧、24 = 漫剧
      // （对齐 api_client 的 tab 映射）。与真实响应同形：游标/session 挂在
      // 被回答的 tab_item 上，卡片藏在 tab.cell_data[].cell_data[] 里。
      switch (params['tab_type']) {
        case '8':
          return {
            'code': 0,
            'data': {
              'tab_index': 0,
              'tab_item': [
                {
                  'tab_type': 8,
                  'title': '看剧',
                  'next_offset': 6,
                  'has_more': true,
                  'session_id': 'sess-drama',
                  'cell_data': [
                    {
                      'show_type': 384,
                      'cell_name': '短剧',
                      'cell_data': [
                        {
                          'video_data': [
                            for (var i = 1; i <= 9; i++)
                              {
                                'series_id_str': 'v$i',
                                'series_title':
                                    _dramaTitles[(i - 1) % _dramaTitles.length],
                                'series_cover': videoCoverUrl,
                                'episode_cnt': '${40 + i}',
                                'score': i.isEven ? '8.2' : '8.0',
                                // 可选元信息：推荐理由 / rec_text（热度）各一行，
                                // 有就显示；集数固定一行。
                                if (i % 3 == 0) 'recommend_reason_list': '{"tag_info":{"text":"上新"},"rec_tags":[{"content":"系列剧·40万人在追"}]}',
                                if (i % 3 == 1) 'rec_text': '${i * 10}万热度',
                                if (i % 3 == 1) 'show_rec_text': true,
                              },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          };
        case '24':
          return {
            'code': 0,
            'data': {
              'tab_index': 0,
              'tab_item': [
                {
                  'tab_type': 24,
                  'title': '漫剧',
                  // 漫剧实测没有游标：只回首页一屏，这里也模拟到底。
                  'next_offset': 0,
                  'has_more': false,
                  'cell_data': [
                    {
                      'show_type': 384,
                      'cell_name': '漫剧',
                      'cell_data': [
                        {
                          'video_data': [
                            for (var i = 1; i <= 12; i++)
                              {
                                'pseries_id': 'a$i',
                                'series_name':
                                    _animeTitles[(i - 1) % _animeTitles.length],
                                'series_cover': '',
                                'episode_cnt': '${12 + i * 2}',
                                'score': '8.0',
                                if (i % 3 == 0) 'recommend_reason_list': '{"tag_info":{"text":"上新"},"sub_title_list":[{"content":"剧情"},{"content":"149集"}]}',
                                if (i % 3 == 1) 'rec_text': '${i * 10}万热度',
                                if (i % 3 == 1) 'show_rec_text': true,
                              },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          };
        default:
          return {
            'code': 0,
            'data': {
              'tab_index': 0,
              'tab_item': [
                {
                  'tab_type': 2,
                  'title': '推荐',
                  'next_offset': 10,
                  'has_more': false,
                  'session_id': 'sess-preview',
                  'cell_data': [
                    {
                      'show_type': 384,
                      'cell_name': '猜你喜欢',
                      'cell_data': [
                        {
                          'book_data': [
                            for (var i = 1; i <= novelItemCount; i++)
                              {
                                'book_id': '$i',
                                'book_name': titles[(i - 1) % titles.length],
                                'author': _authors[(i - 1) % _authors.length],
                                'category': i.isEven ? '玄幻' : '都市',
                                'word_number': '${i * 180000}',
                                'score': i.isEven ? '9.3' : '8.8',
                                // 封面主色：真实响应 27/27 都带；封面没加载出来时当占位底色。
                                'color_dominate':
                                    _coverColors[(i - 1) % _coverColors.length],
                                // 可选元信息：i%3==0 推荐理由，i%3==1 热度；
                                // 作者固定一行，评分走封面角标。
                                if (i % 3 == 0)
                                  'recommend_reason_list': [
                                    {'content': '巅峰榜No.$i'},
                                  ],
                                if (i % 3 == 1) 'rank_score': '$i万热度',
                                'thumb_url': bookCoverUrl,
                              },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          };
      }
    }
    if (path.startsWith('/api/v1/search')) {
      // 漫剧的搜索与翻页兜底：上游没有漫剧搜索 tab，卡片混在短剧搜索 tab
      // 里，靠 genre=205 / 「漫剧」标签区分（见 lib/features/recommend/content_source.dart 的 ManjuSource）。
      if (params['query'] == '漫剧') {
        return _videoSearchPayload(11, [
          for (var i = 1; i <= searchItemCount; i++)
            {
              'pseries_id': 'p$i',
              'series_name': _animeTitles[(i - 1) % _animeTitles.length],
              'series_intro': '这是第 $i 条漫剧搜索结果的简介，用来验证翻页兜底与横向列表排版。',
              'episode_cnt': '${12 + i * 2}',
              'series_cover': '',
              'genre': 205,
            },
        ]);
      }
      // 搜索接口的 tab_type 与首页流不同：3 = 书籍、11 = 短剧。
      switch (params['tab_type']) {
        case '11':
          return _videoSearchPayload(11, [
            for (var i = 1; i <= searchItemCount; i++)
              {
                'series_id_str': 'vs$i',
                'series_title':
                    '搜索结果 ${_dramaTitles[(i - 1) % _dramaTitles.length]}',
                'series_intro': '这是第 $i 条短剧搜索结果的简介，用来验证横向列表两行省略与排版是否和小说搜索一致。',
                'episode_cnt': '${40 + i}',
                'series_cover': '',
              },
          ]);
        default:
          return {
            'code': 0,
            'data': {
              'search_tabs': [
                {
                  'tab_type': 3,
                  'title': '书籍',
                  'next_offset': 10,
                  'data': [
                    for (var i = 1; i <= searchItemCount; i++)
                      {
                        'book_data': {
                          'book_id': 's$i',
                          'book_name':
                              '搜索结果 ${titles[(i - 1) % titles.length]}',
                          'author': '作者$i',
                          'abstract': '这是第 $i 条搜索结果的简介，用来验证两行省略与排版。',
                          'thumb_url': '',
                        },
                      },
                  ],
                },
              ],
            },
          };
      }
    }
    if (path.startsWith('/api/v1/series/')) {
      return {
        'code': 0,
        'data': {
          'video_data': {
            'series_id_str': 'v1',
            'series_title': '详情标题',
            'series_cover': detailSeriesCoverUrl,
            'series_intro': '',
            'episode_cnt': '40',
            'category_schema': '[{"name":"都市"}]',
            'series_play_cnt': '12345',
            'score': '8.2',
          },
        },
      };
    }
    if (path.endsWith('/comments')) {
      // 书评（旧接口形状：data.comment[] + comment_cnt / context /
      // next_offset）。时间戳按「相对现在」的偏移生成，timeLabel() 才会稳定
      // 输出「2天前」这类相对文案，golden 不会随运行时间变化。
      return {
        'code': 0,
        'data': {
          'comment_cnt': 3,
          'context': '2.6万人点评',
          'next_offset': 3,
          'has_more': false,
          'comment': [
            {
              'comment_id': 'rc1',
              'text': '陈平安的成长线写得很扎实，剑气长城那一段反复看了好几遍，越读越有味道。',
              'score': 9,
              'digg_count': 328,
              'reply_count': 12,
              'create_timestamp': _secondsAgo(const Duration(days: 2)),
              'user_info': {
                'base_info': {'user_name': '一蓑烟雨', 'user_avatar': ''},
              },
            },
            {
              'comment_id': 'rc2',
              'text': '前期节奏偏慢，后面渐入佳境。',
              'score': 8,
              'digg_count': 96,
              'reply_count': 3,
              'create_timestamp': _secondsAgo(const Duration(hours: 5)),
              'user_info': {
                'base_info': {'user_name': '翻书人', 'user_avatar': ''},
              },
            },
            {
              'comment_id': 'rc3',
              'text': '人物群像立得住，配角也有自己的高光。',
              'score': 10,
              'digg_count': 521,
              'reply_count': 20,
              'create_timestamp': _secondsAgo(const Duration(days: 9)),
              'user_info': {
                'base_info': {'user_name': '剑气长存', 'user_avatar': ''},
              },
            },
          ],
        },
      };
    }
    if (path.endsWith('/detail')) {
      return {
        'code': 0,
        'data': {
          'book_id': '1',
          'book_name': '剑来',
          'author_info': {'name': '烽火戏诸侯', 'id': '2_1'},
          'abstract':
              '大千世界，无奇不有。我陈平安，唯有一剑，可搬山，倒海，降妖，镇魔，敕神，摘星，断江，摧城，开天！'
              '这是一段用来验证简介折叠与展开的长文本，详情页默认只显示四行。',
          'word_number': '1328318',
          'creation_status': '0',
          'content_chapter_number': '1024',
          'read_count': '1.2万人在读',
          'score': '9.3',
          'tags': ['玄幻', '仙侠', '热血', '连载'],
          'category': '玄幻',
          'last_chapter_title': '第一千零二十四章 开天',
          if (detailCoverUrl.isNotEmpty) 'thumb_url': detailCoverUrl,
        },
      };
    }
    if (path.endsWith('/directory')) {
      return {
        'code': 0,
        'data': {
          'item_data_list': [
            for (var i = 1; i <= directoryChapterCount; i++)
              {
                'item_id': 'c$i',
                'title':
                    '第${_cn(i)}章 ${_chapterNames[(i - 1) % _chapterNames.length]}',
                'volume_name': i <= 12 ? '第一卷' : '第二卷',
              },
          ],
        },
      };
    }
    // 章末/段评计数（阅读页段评气泡与「本章评论」入口）。
    if (path.contains('/chapters/') && path.endsWith('/reviews')) {
      return {
        'code': 0,
        'data': {
          'item_version': 'v-preview',
          'data': {
            '0': {
              'count': 3,
              'infos': <dynamic>[],
              'user_count': 1,
              'is_author_comment': false,
            },
            '2': {
              'count': 12,
              'infos': <dynamic>[],
              'user_count': 0,
              'is_author_comment': true,
            },
            '8': {
              'count': 5,
              'infos': <dynamic>[],
              'user_count': 0,
              'is_author_comment': false,
            },
            '10000': {
              'count': 20,
              'infos': <dynamic>[],
              'user_count': 0,
              'is_author_comment': false,
            },
          },
        },
      };
    }
    // 段评正文（点气泡/章末入口打开的面板）。
    if (path.startsWith('/api/v1/books/') && path.endsWith('/reviews')) {
      return {
        'code': 0,
        'data': {
          'common_list_info': {'total': 2, 'has_more': false, 'cursor': ''},
          'data_list': [
            for (var i = 0; i < 2; i++)
              {
                'comment': {
                  'comment_id': 'pc$i',
                  'common': {
                    'content': {'text': '预览段评 ${i + 1}'},
                    'create_timestamp': 1756000000 + i,
                    'user_info': {
                      'base_info': {'user_name': '读者${i + 1}'},
                    },
                  },
                  'stat': {'digg_count': i, 'reply_count': 0},
                },
              },
          ],
        },
      };
    }
    if (path.contains('/chapters/')) {
      return {
        'code': 0,
        'data': {
          'content_decrypted': true,
          'title': '第一章',
          'content': [
            for (var p = 0; p < 9; p++)
              '<p idx="$p">${_paragraphs[p % _paragraphs.length]}${'这是用来验证分页与中文排版的一段正文，长度足够撑满一屏中的若干行。' * 2}</p>',
          ].join(),
        },
      };
    }
    return {'code': 0, 'data': {}};
  }

  /// 书城卡片标题（「我的页」书架假数据也复用它）。
  static const titles = [
    '剑来',
    '诡秘之主',
    '大奉打更人',
    '夜的命名术',
    '赤心巡天',
    '宿命之环',
    '凡人修仙传',
    '遮天',
    '完美世界',
  ];

  static const _authors = ['烽火戏诸侯', '爱潜水的乌贼', '卖报小郎君', '会说话的肘子', '情何以甚'];

  /// 封面主色样本（取自真实响应 `color_dominate`）：golden 里用它渲染占位色。
  static const _coverColors = [
    '#786858',
    '#201818',
    '#382820',
    '#131F37',
    '#202838',
    '#A98F6D',
    '#305018',
    '#b87850',
    '#c8d0d0',
  ];
  static const _dramaTitles = [
    '十八岁太奶奶驾到，重整家族荣耀',
    '父皇，您别再逼我做皇帝了',
    '退役归来，这个保镖不好惹',
    '二婚嫁对人，前夫悔破防',
    '急诊室摸鱼，全院科室疯狂求我出手',
    '一念沉沦，霍总心动了',
  ];
  static const _animeTitles = [
    '开局签到荒古圣体',
    '我在精神病院学斩神',
    '斗破苍穹·动态漫',
    '完美世界·漫剧',
    '吞噬星空·动态漫',
    '武王伐纣·漫剧',
  ];
  static const _chapterNames = ['山中有剑', '少年游', '问心', '风雪夜归人', '青衫仗剑'];
  static const _paragraphs = [
    '大千世界，无奇不有。',
    '陈平安抬头看了一眼天色，背起竹篓往山上走。',
    '山风穿过松林，带着一股凉意。',
  ];

  Map<String, dynamic> _videoSearchPayload(
    int tabType,
    List<Map<String, dynamic>> cards,
  ) => {
    'code': 0,
    'data': {
      'search_tabs': [
        {
          'tab_type': tabType,
          'title': tabType == 11 ? '短剧' : '漫画',
          'next_offset': 10,
          'data': [
            for (final card in cards) {'video_data': card},
          ],
        },
      ],
    },
  };

  static String _cn(int n) {
    const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    if (n <= 10) return n == 10 ? '十' : digits[n];
    if (n < 20) return '十${digits[n - 10]}';
    final tens = n ~/ 10;
    final ones = n % 10;
    return '${digits[tens]}十${ones == 0 ? '' : digits[ones]}';
  }

  /// 距今 [age] 之前的秒级时间戳（上游旧接口用秒）。
  static int _secondsAgo(Duration age) =>
      DateTime.now().subtract(age).millisecondsSinceEpoch ~/ 1000;
}

/// 预览用内存缓存：widget 测试里 path_provider/真实磁盘 IO 在 fake async 下
/// 不会完成，会让正文一直停在 loading。这里直接用内存实现，行为与磁盘实现
/// 等价（只负责命中/落缓存，不影响页面形态）。
class PreviewChapterCache extends ReaderChapterCache {
  PreviewChapterCache() : super(supportDirectory: unsupportedDirectory);

  final Map<String, ChapterContent> _store = <String, ChapterContent>{};

  @override
  Future<ReaderChapterHit?> get(String chapterId) async {
    final content = _store[chapterId];
    return content == null
        ? null
        : ReaderChapterHit(content: content, isStale: false);
  }

  @override
  Future<void> put(ChapterContent content) async {
    _store[content.id] = content;
  }
}

Future<Directory> unsupportedDirectory() async =>
    throw UnsupportedError('预览缓存不应访问磁盘');

/// 组件测试用的空离线区存储。
///
/// 与 [PreviewChapterCache] 同因：path_provider 在 widget test 里没有平台实现，
/// 真实离线目录的真实 IO Future 永远不会完成，页面只要 watch 离线 manifest
/// 或任务，pumpAndSettle 就会卡死。预览夹具统一注入"没有离线内容"的存储：
/// 读 manifest / 正文立即 miss，阅读页退回 自动缓存 → 网络，等价于未下载过。
///
/// stats 故意保持 pending：设置页 golden 记录的是现有"统计中…"形态，离线统计
/// 不在当前任务范围，换成 0 个会无故改动 settings golden。
class EmptyOfflineBookStore extends OfflineBookStore {
  EmptyOfflineBookStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  @override
  Future<OfflineBook?> read(String bookId) async => null;

  @override
  Future<ChapterContent?> readChapter(String bookId, String chapterId) async =>
      null;

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() => Completer<OfflineStats>().future;
}

/// 短剧离线区的空实现；用途与 [EmptyOfflineBookStore] 相同。
class EmptyOfflineSeriesStore extends OfflineSeriesStore {
  EmptyOfflineSeriesStore()
    : super(paths: OfflinePaths(rootDirectory: unsupportedDirectory));

  @override
  Future<OfflineSeries?> read(String seriesId) async => null;

  @override
  Future<void> cleanupPartFiles() async {}

  @override
  Future<OfflineStats> stats() => Completer<OfflineStats>().future;
}

/// 预览页面的离线依赖覆写：pumpPreview 的页面一律不碰真实离线目录。
// ignore: strict_top_level_inference
previewOfflineOverrides() => [
  offlineBookStoreProvider.overrideWithValue(EmptyOfflineBookStore()),
  offlineSeriesStoreProvider.overrideWithValue(EmptyOfflineSeriesStore()),
];

/// 测试环境默认没有中文字体（渲染成豆腐块）。加载系统里的 Arial Unicode
/// 作为预览字体，让 golden 能真实反映中文排版与断行。
const previewFontFamily = 'PreviewCJK';

Future<void> loadPreviewFont() async {
  for (final path in const [
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    '/System/Library/Fonts/STHeiti Light.ttc',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(previewFontFamily)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return;
  }
}

ThemeData previewTheme(Color seed, [Brightness brightness = Brightness.light]) {
  final base = brightness == Brightness.light
      ? AppTheme.light(seed)
      : AppTheme.dark(seed);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: previewFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: previewFontFamily,
    ),
  );
}

/// 与 app.dart 同构的预览壳：watch 主题色后再建 MaterialApp，
/// 这样换色 golden 能看到「全站真的跟着变」，而不是只有一个页面。
class PreviewApp extends ConsumerWidget {
  const PreviewApp({
    super.key,
    required this.home,
    this.brightness = Brightness.light,
  });

  final Widget home;
  final Brightness brightness;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final theme = previewTheme(seed, brightness);
    return MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      // 页面本身依赖外层 Scaffold 提供 Material（HomeShell 里有），
      // 预览时补一个，保证 InkWell / 文本选择等祖先齐全。
      home: Scaffold(body: home),
    );
  }
}

/// 预览用缓存占用：iPhone 13 上实测量级（视频 339 MB + 封面 41 MB + 章节 16 KB
/// + 遗留日志 116 KB），让「存储」区块的 golden 更接近真机。
const previewCacheUsage = CacheUsage(
  video: 339 * 1024 * 1024,
  image: 41 * 1024 * 1024,
  chapter: 16 * 1024,
  legacyLog: 116 * 1024,
);

Future<void> pumpPreview(
  WidgetTester tester,
  Widget page, {
  ReadingStore? store,
  FakePreviewTransport? transport,
  bool settle = true,
  Brightness brightness = Brightness.light,

  /// 页面专属的 provider 覆写（追加在预览默认覆写之后）。
  ///
  /// 注意不能与下面已覆写的 provider 重复：Riverpod 3 同一个 container 不允许
  /// 重复 override，重复会直接断言。需要换掉列表类 provider 的页面请自建
  /// ProviderScope（示例见 test/ui/cache_center_test.dart 的 pumpCenter）。
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = ApiClient(transport ?? FakePreviewTransport());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        readerChapterCacheProvider.overrideWithValue(PreviewChapterCache()),
        ...previewOfflineOverrides(),
        cacheUsageProvider.overrideWith((ref) async => previewCacheUsage),
        // 离线缓存：widget 测试没有 path_provider，给一组确定性的空数据，
        // 避免设置页/管理页停在「统计中…」（真实数据由离线管理页测试单独注入）。
        offlineNovelStatsProvider.overrideWith(
          (ref) async => const OfflineStats(
            count: 0,
            bytes: 0,
            capBytes: OfflineBookStore.novelCapBytes,
          ),
        ),
        offlineVideoStatsProvider.overrideWith(
          (ref) async => const OfflineStats(
            count: 0,
            bytes: 0,
            capBytes: OfflineSeriesStore.videoCapBytes,
          ),
        ),
        offlineNovelListProvider.overrideWith(
          (ref) async => <OfflineBookSummary>[],
        ),
        offlineVideoListProvider.overrideWith(
          (ref) async => <OfflineSeriesSummary>[],
        ),
        if (store != null) readingStoreProvider.overrideWithValue(store),
        ...extraOverrides,
      ],
      child: PreviewApp(home: page, brightness: brightness),
    ),
  );
  if (!settle) return;
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// 当前可见竖向列表的滚动偏移（跳过 PageView 的横向 Scrollable）。
double verticalOffset(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  return tester.state<ScrollableState>(finder.first).position.pixels;
}
