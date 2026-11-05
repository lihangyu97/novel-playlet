import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/feed/feed_results.dart';
import 'package:novel_playlet/app/feed/feed_search_field.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/shell/floating_navigation_bar.dart';
import 'package:novel_playlet/app/shell/home_shell.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/theme/theme_settings.dart';
import 'package:novel_playlet/app/widgets/detail/detail_common.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/cache/app_cache.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_widgets.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/settings/settings_page.dart';
import 'package:novel_playlet/features/settings/settings_providers.dart';
import 'package:novel_playlet/data/models/video_series.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/video_player_page.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/features/video/widgets/episode_picker.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI 预览：用假 transport 注入固定上游数据，把各页面真实渲染成 PNG。
///
/// 目的不是断言像素，而是让 Lead 在没有模拟器/真机的环境里也能看到真实
/// 布局。更新基线：`flutter test --update-goldens test/ui_preview_test.dart`
///
/// 顺带说明：封面 URL 故意留空，避免 widget 测试里真的发网络请求。
class _FakeTransport extends BackendTransport {
  _FakeTransport() : super(port: 0);

  /// 请求记录（`path?query`），用于断言取消搜索不会重新发请求。
  final calls = <String>[];

  /// 命中这些关键词的搜索返回 500（验证失败后换关键词/重试的 loading 态）。
  final failingQueries = <String>{};

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
                                'book_name': _titles[(i - 1) % _titles.length],
                                'author': _authors[(i - 1) % _authors.length],
                                'category': i.isEven ? '玄幻' : '都市',
                                'word_number': '${i * 180000}',
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
      // 里，靠 genre=205 / 「漫剧」标签区分（对齐 ApiClient.manjuSearch）。
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
                              '搜索结果 ${_titles[(i - 1) % _titles.length]}',
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
          },
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
    if (path.contains('/chapters/')) {
      return {
        'code': 0,
        'data': {
          'content_decrypted': true,
          'title': '第一章',
          'content': [
            for (var p = 0; p < 9; p++)
              '<p>${_paragraphs[p % _paragraphs.length]}${'这是用来验证分页与中文排版的一段正文，长度足够撑满一屏中的若干行。' * 2}</p>',
          ].join(),
        },
      };
    }
    return {'code': 0, 'data': {}};
  }

  static const _titles = [
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
}

/// 预览用内存缓存：widget 测试里 path_provider/真实磁盘 IO 在 fake async 下
/// 不会完成，会让正文一直停在 loading。这里直接用内存实现，行为与磁盘实现
/// 等价（只负责命中/落缓存，不影响页面形态）。
class _PreviewChapterCache extends ReaderChapterCache {
  _PreviewChapterCache() : super(supportDirectory: _unsupportedDirectory);

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

Future<Directory> _unsupportedDirectory() async =>
    throw UnsupportedError('预览缓存不应访问磁盘');

/// 测试环境默认没有中文字体（渲染成豆腐块）。加载系统里的 Arial Unicode
/// 作为预览字体，让 golden 能真实反映中文排版与断行。
const _previewFontFamily = 'PreviewCJK';

Future<void> _loadPreviewFont() async {
  for (final path in const [
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    '/System/Library/Fonts/STHeiti Light.ttc',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(_previewFontFamily)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return;
  }
}

ThemeData _previewTheme(
  Color seed, [
  Brightness brightness = Brightness.light,
]) {
  final base = brightness == Brightness.light
      ? AppTheme.light(seed)
      : AppTheme.dark(seed);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _previewFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: _previewFontFamily,
    ),
  );
}

/// 与 app.dart 同构的预览壳：watch 主题色后再建 MaterialApp，
/// 这样换色 golden 能看到「全站真的跟着变」，而不是只有一个页面。
class _PreviewApp extends ConsumerWidget {
  const _PreviewApp({required this.home, this.brightness = Brightness.light});

  final Widget home;
  final Brightness brightness;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final theme = _previewTheme(seed, brightness);
    return MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      // 页面本身依赖外层 Scaffold 提供 Material（HomeShell 里有），
      // 预览时补一个，保证 InkWell / 文本选择等祖先齐全。
      // 命名路由用于验证「列表点进详情」的 Hero 飞入。
      home: Scaffold(body: home),
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}

/// 预览用缓存占用：iPhone 13 上实测量级（视频 339 MB + 封面 41 MB + 章节 16 KB
/// + 遗留日志 116 KB），让「存储」区块的 golden 更接近真机。
const _previewCacheUsage = CacheUsage(
  video: 339 * 1024 * 1024,
  image: 41 * 1024 * 1024,
  chapter: 16 * 1024,
  legacyLog: 116 * 1024,
);

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  ReadingStore? store,
  _FakeTransport? transport,
  bool settle = true,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = ApiClient(transport ?? _FakeTransport());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        readerChapterCacheProvider.overrideWithValue(_PreviewChapterCache()),
        cacheUsageProvider.overrideWith((ref) async => _previewCacheUsage),
        if (store != null) readingStoreProvider.overrideWithValue(store),
      ],
      child: _PreviewApp(home: page, brightness: brightness),
    ),
  );
  if (!settle) return;
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// 当前分类网格里的封面尺寸。按卡片类型圈定（小说分类是
/// [NovelGridCard]，短剧/漫剧是 [VideoCard]），避免以后同屏出现混合卡片时
/// 拿错对象；保活的隐藏页默认被 finder 的 skipOffstage 跳过。
List<Size> _gridCoverSizes(WidgetTester tester, {required bool novel}) {
  final cards = novel ? find.byType(NovelGridCard) : find.byType(VideoCard);
  final covers = find.descendant(of: cards, matching: find.byType(NovelCover));
  return tester
      .widgetList<NovelCover>(covers)
      .map((cover) => Size(cover.width, cover.height))
      .toList();
}

/// 搜索结果横向列表里的封面尺寸（[FeedResultTile] 圈定）。
List<Size> _searchCoverSizes(WidgetTester tester) {
  final covers = find.descendant(
    of: find.byType(FeedResultTile),
    matching: find.byType(NovelCover),
  );
  return tester
      .widgetList<NovelCover>(covers)
      .map((cover) => Size(cover.width, cover.height))
      .toList();
}

/// 当前可见竖向列表的滚动偏移（跳过 PageView 的横向 Scrollable）。
double verticalOffset(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  return tester.state<ScrollableState>(finder.first).position.pixels;
}

/// 这一页所有封面的高宽比都必须 = [kCoverAspect]（11:8）。
void _expectCoverAspect(WidgetTester tester, String label) {
  final bad = tester
      .widgetList<NovelCover>(find.byType(NovelCover))
      .where(
        (cover) => (cover.height / cover.width - kCoverAspect).abs() > 0.002,
      )
      .map(
        (cover) =>
            '${cover.width.toStringAsFixed(1)}×${cover.height.toStringAsFixed(1)}'
            '(h/w=${(cover.height / cover.width).toStringAsFixed(3)})',
      )
      .toSet();
  expect(bad, isEmpty, reason: '$label 有封面比例不是 11:8：$bad');
}

void main() {
  setUpAll(() async {
    await _loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 当前可见竖向列表的滚动偏移（跳过 PageView 的横向 Scrollable）。
  double verticalOffset(WidgetTester tester) {
    final finder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    return tester.state<ScrollableState>(finder.first).position.pixels;
  }

  testWidgets('推荐页-小说分类', (tester) async {
    await _pump(tester, const RecommendPage());
    // 合并后推荐态不再有「为你推荐 / 短剧推荐」区块标题。
    expect(find.text('为你推荐'), findsNothing);
    expect(find.text('短剧推荐'), findsNothing);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('goldens/recommend.png'),
    );
  });

  testWidgets('推荐页-短剧分类', (tester) async {
    await _pump(tester, const RecommendPage());
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    expect(find.textContaining('太奶奶'), findsWidgets);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('goldens/recommend_drama.png'),
    );
  });

  testWidgets('推荐页-漫剧分类', (tester) async {
    await _pump(tester, const RecommendPage());
    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    expect(find.textContaining('动态漫'), findsWidgets);
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('goldens/recommend_anime.png'),
    );
  });

  testWidgets('推荐页-分类 tabs 横向可滚动', (tester) async {
    await _pump(tester, const RecommendPage());
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.isScrollable, isTrue, reason: '分类 tabs 必须能左右滑动');
    expect(find.byType(Tab), findsNWidgets(3));
    for (final label in ['小说', '短剧', '漫剧']) {
      expect(find.text(label), findsOneWidget, reason: '缺少分类 $label');
    }
  });

  /// A：顶部尺寸收紧——搜索框 40pt、tabs 36pt，搜索+tabs+间距压到 100pt 内。
  testWidgets('推荐页-顶部高度收紧', (tester) async {
    await _pump(tester, const RecommendPage());
    expect(
      tester.getSize(find.byType(FeedSearchField)).height,
      FeedSearchField.height,
    );
    expect(FeedSearchField.height, 40, reason: '搜索框高度应为 40');
    final tabsBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
    expect(
      tabsBottom,
      lessThanOrEqualTo(100),
      reason: '搜索框 + tabs + 间距应压到 100pt 以内，实际 $tabsBottom',
    );
  });

  /// C：上滑浏览时搜索框整条收起，tabs 保留；回到顶部再展开。
  testWidgets('推荐页-上滑收起搜索框、tabs 保留、回顶展开', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    expect(find.byType(FeedSearchField), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing, reason: '上滑后搜索框应收起');
    expect(find.text('小说'), findsOneWidget, reason: 'tabs 必须保留，否则切不了分类');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsOneWidget, reason: '回到顶部应重新展开');
  });

  /// 搜索态不能收起：输入框正在被使用，藏起来用户就不知道自己在搜什么。
  testWidgets('推荐页-搜索态下滚动不收起搜索框', (tester) async {
    final fake = _FakeTransport()..searchItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索态必须保持搜索框可见',
    );
  });

  /// 各分类的折叠状态独立：短剧没滚过要展开，切回已滚动的小说要继续收起。
  /// 收起后左右切分类不能把搜索框弹回来：折叠是页面级状态，与各分类
  /// 自己的滚动位置无关（即使切到的分类还停在顶部）。
  testWidgets('推荐页-收起后切分类保持收起', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing);

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsNothing,
      reason: '切到未滚动的分类也不应重新展开搜索框',
    );
    expect(find.text('短剧'), findsOneWidget);

    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing, reason: '切回来仍保持收起');
  });

  /// 深处回落立即展开：滚得很深时，往回滑的第一下就要看到搜索框，
  /// 不能等一路滚回顶部才展开。
  testWidgets('推荐页-深滚动后往回滑立即展开', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing);
    final deepOffset = verticalOffset(tester);
    expect(deepOffset, greaterThan(300), reason: '前置条件：确实滚了很远');

    // 往回滑一小段（仍在很深的位置）：搜索框必须立刻出现。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 80));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsOneWidget, reason: '往回滑应立即展开搜索框');
    expect(
      verticalOffset(tester),
      greaterThan(300),
      reason: '展开不依赖滚回顶部：此时仍应处于深滚动位置',
    );
  });

  /// 封面尺寸回归：三个分类的推荐流封面必须同宽同高。
  ///
  /// 上游原生比例不同（小说 240×320 = 3:4，短剧 400×571 ≈ 1.427），以前两条
  /// 流各用各的 `coverAspect`；合并成一个页面后更不能出现切分类封面大小跳变。
  /// 切分类后旧页面会被 TabBarView 保活，所以按卡片类型圈定当前分类的封面。
  testWidgets('封面尺寸-三个分类的推荐流一致', (tester) async {
    await _pump(tester, const RecommendPage());
    final novel = _gridCoverSizes(tester, novel: true);
    expect(novel, isNotEmpty);
    expect(novel.map((size) => size.width).toSet(), hasLength(1));
    expect(
      novel.first.height / novel.first.width,
      closeTo(kCoverAspect, 0.001),
    );

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    final drama = _gridCoverSizes(tester, novel: false);
    expect(drama, isNotEmpty);
    expect(drama.map((size) => size.width).toSet(), hasLength(1));
    expect(
      drama.first.height / drama.first.width,
      closeTo(kCoverAspect, 0.001),
    );

    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle();
    final anime = _gridCoverSizes(tester, novel: false);
    expect(anime, isNotEmpty);

    expect(drama.first, novel.first, reason: '短剧与小说封面尺寸必须一致');
    expect(anime.first, novel.first, reason: '漫剧与小说封面尺寸必须一致');
  });

  /// 搜索态也统一：三个分类都是横向列表 + 同一套条目，封面同宽同高。
  testWidgets('封面尺寸-三个分类的搜索结果一致', (tester) async {
    Future<Size> searchOn(String query, {String? tab}) async {
      await _pump(tester, const RecommendPage());
      if (tab != null) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byType(TextField), query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final sizes = _searchCoverSizes(tester);
      expect(sizes, isNotEmpty);
      expect(sizes.map((size) => size.width).toSet(), hasLength(1));
      expect(
        sizes.first.width,
        FeedResultTile.coverWidth,
        reason: '搜索结果封面宽度应走 FeedResultTile.coverWidth',
      );
      expect(
        sizes.first.height / sizes.first.width,
        closeTo(kCoverAspect, 0.001),
      );
      return sizes.first;
    }

    final novel = await searchOn('剑来');
    final drama = await searchOn('太奶奶', tab: '短剧');
    final anime = await searchOn('漫剧', tab: '漫剧');

    expect(drama, novel, reason: '短剧与小说搜索结果封面尺寸必须一致');
    expect(anime, novel, reason: '漫剧与小说搜索结果封面尺寸必须一致');
  });

  group('封面 Hero 飞入', () {
    testWidgets('推荐页-卡片封面都带唯一 Hero tag', (tester) async {
      await _pump(tester, const RecommendPage());
      final cards = tester
          .widgetList<NovelGridCard>(find.byType(NovelGridCard))
          .toList();
      expect(cards, isNotEmpty);
      final tags = cards.map((card) => card.heroTag).toList();
      expect(tags.every((tag) => tag != null), isTrue);
      expect(tags.toSet().length, tags.length, reason: '同一屏封面 Hero tag 必须唯一');
      expect(tags.first, 'cover-novel-recommend-novel-1');
    });

    testWidgets('小说列表点进详情：封面飞入并在返回时飞回', (tester) async {
      final fake = _FakeTransport()
        ..bookCoverUrl = 'https://example.com/cover-1.jpg';
      await _pump(tester, const RecommendPage(), transport: fake);
      final card = tester
          .widget<NovelGridCard>(find.byType(NovelGridCard).first);
      final tag = card.heroTag!;

      await tester.tap(find.byType(NovelGridCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '进详情时应在飞行',
      );
      final detailHero = tester.widget<Hero>(
        find
            .descendant(of: find.byType(DetailPage), matching: find.byType(Hero))
            .first,
      );
      expect(detailHero.tag, tag, reason: '详情页封面必须用同一个 tag 接住 Hero');

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.text(card.item.title), findsWidgets);

      // 返回时 Hero 反向飞回列表卡片。
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '从详情返回时应执行反向封面飞行',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byType(NovelGridCard), findsWidgets);
    });

    testWidgets('短剧列表点进详情：封面飞入并在返回时飞回', (tester) async {
      final fake = _FakeTransport()
        ..videoCoverUrl = 'https://example.com/drama-1.jpg';
      await _pump(tester, const RecommendPage(), transport: fake);
      await tester.tap(find.text('短剧'));
      await tester.pumpAndSettle();
      final card = tester.widget<VideoCard>(find.byType(VideoCard).first);
      final tag = card.heroTag!;
      expect(tag, startsWith('cover-video-recommend-drama-'));

      await tester.tap(find.byType(VideoCard).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(VideoDetailPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '进详情时应在飞行',
      );
      final detailHero = tester.widget<Hero>(
        find
            .descendant(
              of: find.byType(VideoDetailPage),
              matching: find.byType(Hero),
            )
            .first,
      );
      expect(detailHero.tag, tag, reason: '短剧详情封面必须用同一个 tag 接住 Hero');

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(VideoDetailPage), findsOneWidget);

      Navigator.of(tester.element(find.byType(VideoDetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey('cover-hero-flight')),
        findsOneWidget,
        reason: '从短剧详情返回时应执行反向封面飞行',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(VideoDetailPage), findsNothing);
    });

    testWidgets('短剧详情-加载中也先画封面（Hero 目标从第一帧就存在）', (tester) async {
      final fake = _FakeTransport()
        ..responseDelay = const Duration(milliseconds: 80);
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        cover: 'https://example.com/list-drama.jpg',
        episodeCount: 40,
      );
      await _pump(
        tester,
        const VideoDetailPage(
          seriesId: 'v1',
          preview: preview,
          heroTag: 'cover-video-test-v1',
        ),
        transport: fake,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 30));
      // 背景/Hero 目标从第一帧就在；文字信息等接口回来再淡入，不再转圈。
      expect(find.byType(Hero), findsOneWidget);
      expect(find.text('测试短剧'), findsNothing, reason: '文字信息等数据回来再淡入');
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '详情加载不再显示转圈 loading',
      );
      final heightBefore = tester
          .getSize(find.byType(DetailCoverBackdrop))
          .height;

      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('详情标题'), findsOneWidget);
      expect(find.text('选集'), findsOneWidget);
      expect(
        tester.getSize(find.byType(DetailCoverBackdrop)).height,
        heightBefore,
        reason: '接口回来后背景高度不能变',
      );
    });

    testWidgets('小说详情-接口回来后不替换列表封面（不闪）', (tester) async {
      const preview = NovelItem(
        id: '1',
        title: '剑来',
        cover: 'https://example.com/list.jpg',
        author: '作者',
      );
      final fake = _FakeTransport()
        ..detailCoverUrl = 'https://example.com/detail.jpg';
      await _pump(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: fake,
      );
      final backdrop = tester.widget<DetailCoverBackdrop>(
        find.byType(DetailCoverBackdrop),
      );
      expect(
        backdrop.cover,
        preview.cover,
        reason: '详情接口回来不应把封面换成 detail.jpg（会让 Hero 落位后再加载一次）',
      );
      expect(find.byType(NovelCover), findsNothing, reason: '详情页不再单独画小封面');
    });

    testWidgets('封面 Hero 支持 iOS 手势返回（侧滑也能飞回去）', (tester) async {
      final fake = _FakeTransport()
        ..bookCoverUrl = 'https://example.com/cover-1.jpg';
      await _pump(tester, const RecommendPage(), transport: fake);
      final listHeroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
      expect(listHeroes, isNotEmpty);
      expect(
        listHeroes.every((hero) => hero.transitionOnUserGestures),
        isTrue,
        reason: '列表封面 Hero 必须支持手势转场，否则 iOS 侧滑返回不飞',
      );

      final card = tester.widget<NovelGridCard>(
        find.byType(NovelGridCard).first,
      );
      await tester.tap(find.byType(NovelGridCard).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      final detailHero = tester.widget<Hero>(
        find
            .descendant(of: find.byType(DetailPage), matching: find.byType(Hero))
            .first,
      );
      expect(detailHero.tag, card.heroTag);
      expect(detailHero.transitionOnUserGestures, isTrue);
    });

    testWidgets('小说详情-加载中不转圈', (tester) async {
      final fake = _FakeTransport()
        ..responseDelay = const Duration(milliseconds: 80);
      await _pump(
        tester,
        const DetailPage(bookId: '1'),
        transport: fake,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '详情加载阶段只保留封面背景，不再显示转圈',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('剑来'), findsWidgets);
    });

    testWidgets('小说详情-作者行带状态字数，评分/在读/更新至合并一行', (tester) async {
      const preview = NovelItem(id: '1', title: '剑来', author: '作者');
      await _pump(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: _FakeTransport(),
      );

      // 作者 · 状态 · 字数 在同一行；分类不再出现（简介里已有标签）。
      expect(find.text('烽火戏诸侯 · 连载中 · 132.8万字'), findsOneWidget);
      expect(find.textContaining('玄幻 ·'), findsNothing);

      // 评分 / 在读 / 更新至 合并成一行：三者的中线应一致。
      final score = tester.getCenter(find.text('9.3')).dy;
      final readers = tester.getCenter(find.text('1.2万人在读')).dy;
      final updated = tester
          .getCenter(find.text('更新至 第一千零二十四章 开天'))
          .dy;
      expect(readers, closeTo(score, 0.5));
      expect(updated, closeTo(score, 0.5));
    });

    testWidgets('短剧详情-接口回来后不替换列表封面（不闪）', (tester) async {
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        cover: 'https://example.com/list-drama.jpg',
        episodeCount: 40,
      );
      final fake = _FakeTransport()
        ..detailSeriesCoverUrl = 'https://example.com/detail-drama.jpg';
      await _pump(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: fake,
      );
      final backdrop = tester.widget<DetailCoverBackdrop>(
        find.byType(DetailCoverBackdrop),
      );
      expect(
        backdrop.cover,
        preview.cover,
        reason: '短剧详情接口回来不应换图',
      );
    });

    testWidgets('详情页-封面同时作为顶部背景（顶部不透明到底部透明）', (tester) async {
      const preview = NovelItem(
        id: '1',
        title: '剑来',
        cover: 'https://example.com/list.jpg',
      );
      await _pump(
        tester,
        const DetailPage(bookId: '1', preview: preview),
        transport: _FakeTransport(),
      );
      final backdrop = find.byWidgetPredicate(
        (widget) => widget is ShaderMask && widget.blendMode == BlendMode.dstIn,
      );
      expect(backdrop, findsOneWidget, reason: '封面应作为背景并做透明度渐变');
    });

    testWidgets('短剧详情-分类只在简介标签里出现一次', (tester) async {
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        episodeCount: 40,
      );
      await _pump(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: _FakeTransport(),
      );
      expect(find.text('全 40 集 · 1.2 万 次播放'), findsOneWidget);
      expect(find.text('全 40 集'), findsNothing, reason: '集数和播放量应在同一行');
      expect(find.text('都市'), findsOneWidget, reason: '分类只作为简介标签出现一次');
      expect(
        find.textContaining('都市 ·'),
        findsNothing,
        reason: '信息行不应再出现点拼接的分类',
      );
    });

    testWidgets('推荐页与书架同书共存时 Hero tag 不冲突', (tester) async {
      SharedPreferences.setMockInitialValues({
        'shelf_books_v1': jsonEncode([
          {'id': '1', 'title': '剑来', 'cover': '', 'author': '作者1'},
        ]),
      });
      await _pump(tester, const HomeShell());
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      // 两个保活页面里同一本书各有一张封面，tag 必须带来源维度，否则跳转时
      // Hero 会抛「multiple heroes share the same tag」。
      final tags = tester
          .widgetList<Hero>(find.byType(Hero, skipOffstage: false))
          .map((hero) => hero.tag)
          .toList();
      expect(tags.toSet().length, tags.length, reason: '保活页面之间 Hero tag 不能重复');
      expect(tags, contains('cover-novel-recommend-novel-1'));
      expect(tags, contains('cover-novel-mine-shelf-1'));
    });
  });

  testWidgets('推荐页-搜索框内容垂直居中', (tester) async {
    await _pump(tester, const RecommendPage());
    final hint = tester.getRect(find.text('搜索书名/作者'));
    final icon = tester.getRect(find.byIcon(Icons.search_rounded));
    final field = tester.getRect(find.byType(TextField));
    expect(
      (hint.center.dy - icon.center.dy).abs(),
      lessThan(1.2),
      reason: '提示文字与放大镜必须同一条水平中线',
    );
    expect(
      (hint.center.dy - field.center.dy).abs(),
      lessThan(1.2),
      reason: '提示文字必须在输入区垂直居中',
    );
  });

  testWidgets('推荐页-搜索框输入前后高度不变', (tester) async {
    await _pump(tester, const RecommendPage());
    final before = tester.getSize(find.byType(TextField)).height;
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.pump();
    final after = tester.getSize(find.byType(TextField)).height;
    expect(after, before, reason: '输入后出现清空按钮不应把搜索框撑高');
  });

  testWidgets('推荐页-搜索态', (tester) async {
    await _pump(tester, const RecommendPage());
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('goldens/recommend_search.png'),
    );
  });

  testWidgets('首页-推荐/我的两个底部 tab', (tester) async {
    await _pump(tester, const HomeShell());
    expect(find.byType(FloatingNavigationBar), findsOneWidget);
    expect(find.byType(FloatingNavigationDestination), findsNWidgets(2));
    // 内容从胶囊下面穿过：列表 viewport 必须铺到胶囊顶边以下。
    final listRect = tester.getRect(find.byType(CustomScrollView).first);
    final barRect = tester.getRect(find.byType(FloatingNavigationBar));
    expect(
      listRect.bottom,
      greaterThan(barRect.top),
      reason: '悬浮底栏应叠在列表上方，而不是把 body 顶上去',
    );
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    // 合并后底部只剩「推荐 / 我的」，分类在搜索框下方的 tabs 里。
    expect(find.text('小说'), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/home.png'),
    );

    // 切 tab 是横向滑过去，而不是硬切：动画中途「我的」页应该处于屏幕内
    // 的某个中间位置。
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final mineDx = tester.getTopLeft(find.byType(MinePage)).dx;
    expect(mineDx, greaterThan(0), reason: '切换过程中页面应在横向滑动');
    expect(mineDx, lessThan(390), reason: '切换过程中页面应在横向滑动');
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.byType(MinePage)).dx, 0);
    expect(find.byType(MinePage), findsOneWidget);
  });

  testWidgets('首页-切 tab 回来保留推荐页滚动位置', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const HomeShell(), transport: fake);
    expect(verticalOffset(tester), 0);

    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final scrolled = verticalOffset(tester);
    expect(scrolled, greaterThan(100), reason: '多屏内容应该能滚动');

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      verticalOffset(tester),
      closeTo(scrolled, 0.5),
      reason: 'PageView keep-alive 后滚动位置必须保持',
    );
  });

  testWidgets('首页-滚动后顶部收起', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const HomeShell(), transport: fake);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byType(FeedSearchField), findsNothing);
    expect(find.text('小说'), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/home_scrolled.png'),
    );
  });

  testWidgets('推荐页-内容区左右滑动切分类', (tester) async {
    await _pump(tester, const RecommendPage());
    await tester.drag(find.byType(TabBarView), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.text('搜索短剧'), findsOneWidget);
    expect(find.textContaining('太奶奶'), findsWidgets);

    await tester.drag(find.byType(TabBarView), const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.text('搜索书名/作者'), findsOneWidget);
  });

  testWidgets('推荐页-切分类回来保留滚动位置', (tester) async {
    final fake = _FakeTransport()..novelItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    expect(verticalOffset(tester), 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -420));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final scrolled = verticalOffset(tester);
    expect(scrolled, greaterThan(100), reason: '多屏内容应该能滚动');

    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(
      verticalOffset(tester),
      closeTo(scrolled, 0.5),
      reason: '保活后滚动位置必须保持',
    );
  });

  /// 搜索结果的滚动不能污染推荐流的折叠状态：取消搜索后推荐流还在顶部，
  /// 搜索框必须重新展开（不能还停在「搜索时滚过」的收起态）。
  testWidgets('推荐页-取消搜索后按推荐流位置展开', (tester) async {
    final fake = _FakeTransport()..searchItemCount = 30;
    await _pump(tester, const RecommendPage(), transport: fake);
    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(verticalOffset(tester), greaterThan(100), reason: '搜索结果应能滚动');
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索态滚动时输入框必须保持可见',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '取消搜索后推荐流在顶部，搜索框应展开而不是继承搜索结果的滚动位置',
    );
  });

  testWidgets('推荐页-取消搜索回显推荐流且不重新请求', (tester) async {
    final fake = _FakeTransport();
    await _pump(tester, const RecommendPage(), transport: fake);
    int countOf(String prefix) =>
        fake.calls.where((call) => call.startsWith(prefix)).length;

    expect(countOf('/api/v1/search'), 0);

    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final searchCalls = countOf('/api/v1/search');
    expect(searchCalls, greaterThanOrEqualTo(1));

    final feedCalls = countOf('/api/v1/recommend/homepage');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('取消'), findsNothing);
    expect(countOf('/api/v1/search'), searchCalls, reason: '取消搜索只回显快照，不应再发请求');
    expect(
      countOf('/api/v1/recommend/homepage'),
      feedCalls,
      reason: '取消搜索不应重新拉推荐流',
    );
    expect(find.text('剑来'), findsWidgets, reason: '应回到推荐流');
  });

  testWidgets('推荐页-搜索失败后换关键词先显示 loading 而不是旧错误', (tester) async {
    final fake = _FakeTransport()
      ..failingQueries.add('失败')
      ..responseDelay = const Duration(milliseconds: 60);
    await _pump(tester, const RecommendPage(), transport: fake);

    await tester.enterText(find.byType(TextField), '失败');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('boom'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '剑来');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // 请求还没回来：必须显示 loading，而不是把上一次的 ErrorView 钉住。
    await tester.pump();
    expect(find.text('boom'), findsNothing);
    expect(find.text('搜索中…'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('搜索结果 剑来'), findsOneWidget);
  });

  testWidgets('推荐页-首屏失败立即显示错误页（不等待自动重试）', (tester) async {
    // Riverpod 3 默认对异常自动重试 10 次（约 38 秒），期间状态一直是 loading，
    // 错误页会被推迟。这里不用 pumpAndSettle（会把自动重试跑完），固定时长
    // 观察：首请求失败后必须马上出现 ErrorView，且只发过一次请求。
    final fake = _FakeTransport()..failRecommend = true;
    await _pump(tester, const RecommendPage(), transport: fake, settle: false);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('boom'), findsOneWidget);
    expect(
      fake.calls
          .where((call) => call.startsWith('/api/v1/recommend/homepage'))
          .length,
      1,
      reason: '关闭自动重试后，失败应立即交给用户手动重试',
    );
  });

  testWidgets('短剧详情-底部收藏与播放栏', (tester) async {
    const preview = VideoSeries(
      id: 'v1',
      title: '测试短剧',
      episodeCount: 40,
    );
    await _pump(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: _FakeTransport(),
    );
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final favoriteButton = find.descendant(
      of: find.byType(OutlinedButton),
      matching: find.text('已收藏'),
    );
    expect(favoriteButton, findsOneWidget, reason: '底部收藏按钮应变成「已收藏」');
    final store = ReadingStore();
    expect(await store.isVideoOnShelf('v1'), isTrue);

    // 等「已收藏」snackbar 消失，避免它挡住底部按钮。
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(favoriteButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(OutlinedButton),
        matching: find.text('收藏'),
      ),
      findsOneWidget,
    );
    expect(await store.isVideoOnShelf('v1'), isFalse);
  });

  testWidgets('短剧详情-有观看进度时显示继续观看', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '测试短剧',
      episodeIndex: 2,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });
    const preview = VideoSeries(
      id: 'v1',
      title: '测试短剧',
      episodeCount: 40,
    );
    await _pump(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: _FakeTransport(),
    );
    expect(find.text('继续观看 · 第 3 集'), findsOneWidget);
  });

  testWidgets('我的页-短剧最近观看点击后进播放页', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '太奶奶的短剧',
      episodeIndex: 4,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });
    await _pump(tester, const MinePage());
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    await tester.tap(find.text('看到第 5 集'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(VideoPlayerPage), findsOneWidget);
  });

  testWidgets('我的页（短剧收藏与历史）', (tester) async {
    final progress = VideoWatchProgress(
      seriesId: 'v1',
      title: '太奶奶的短剧',
      cover: '',
      episodeIndex: 4,
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'video_shelf_v1': jsonEncode([
        VideoSeries(
          id: 'v1',
          title: '太奶奶的短剧',
          episodeCount: 40,
        ).toStorageJson(),
        const VideoSeries(
          id: 'v2',
          title: '另一部短剧',
          episodeCount: 12,
        ).toStorageJson(),
      ]),
      'video_progress_v1': jsonEncode({'v1': progress.toJson()}),
      'video_history_v1': jsonEncode([progress.toJson()]),
    });

    await _pump(tester, const MinePage());
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.text('最近观看 1 条 · 收藏 2 部'), findsOneWidget);
    expect(find.text('太奶奶的短剧'), findsWidgets);
    expect(find.text('看到第 5 集'), findsOneWidget);
    expect(find.text('另一部短剧'), findsOneWidget);
    // 最近观看和最近阅读同一版式：封面在左、箭头在右。
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsWidgets);
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_drama.png'),
    );
  });

  group('短剧选集', () {
    testWidgets('默认折叠，展开后 36 集一个 tab、每行 6 个、只显示集数', (tester) async {
      final fake = _FakeTransport()..directoryChapterCount = 80;
      const preview = VideoSeries(
        id: 'v1',
        title: '测试短剧',
        episodeCount: 80,
      );
      await _pump(
        tester,
        const VideoDetailPage(seriesId: 'v1', preview: preview),
        transport: fake,
      );

      final episodeButtons = find.descendant(
        of: find.byType(EpisodePicker),
        matching: find.byType(OutlinedButton),
      );
      // 默认展开：直接看到选集和集数按钮。
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('共 80 集'), findsOneWidget);
      expect(episodeButtons, findsWidgets);

      // 36 集一个 tab，自动分组。
      expect(find.text('1-36'), findsOneWidget);
      expect(find.text('37-72'), findsOneWidget);
      expect(find.text('73-80'), findsOneWidget);
      // 只显示集数，没有「第 x 集」。
      expect(find.text('第 1 集'), findsNothing);
      expect(find.text('1'), findsOneWidget);

      // 一行 6 个：前 6 个的 y 相同，第 7 个换行。
      final firstRow = [
        for (var i = 1; i <= 6; i++) tester.getTopLeft(find.text('$i')),
      ];
      for (final position in firstRow) {
        expect(position.dy, closeTo(firstRow.first.dy, 0.5));
      }
      expect(
        tester.getTopLeft(find.text('7')).dy,
        greaterThan(firstRow.first.dy),
        reason: '一行应放 6 个，第 7 个换行',
      );

      // 切到第二个 tab，看到第 37 集。
      await tester.tap(find.text('37-72'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.text('37'), findsOneWidget);
      expect(find.text('36'), findsNothing);

      // 点标题可以收起，再点可以重新展开。
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(episodeButtons, findsNothing);
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(episodeButtons, findsWidgets);
    });
  });

  testWidgets('短剧详情-选集展开（36 集一个 tab、一行 6 个）', (tester) async {
    final fake = _FakeTransport()..directoryChapterCount = 80;
    const preview = VideoSeries(
      id: 'v1',
      title: '测试短剧',
      episodeCount: 80,
    );
    await _pump(
      tester,
      const VideoDetailPage(seriesId: 'v1', preview: preview),
      transport: fake,
    );
    await expectLater(
      find.byType(VideoDetailPage),
      matchesGoldenFile('goldens/video_detail_episodes.png'),
    );
  });

  testWidgets('详情页', (tester) async {
    await _pump(tester, const DetailPage(bookId: '1'));
    await expectLater(
      find.byType(DetailPage),
      matchesGoldenFile('goldens/detail.png'),
    );
  });

  testWidgets('阅读页', (tester) async {
    await _pump(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('goldens/reader.png'),
    );
  });

  testWidgets('阅读页-工具栏', (tester) async {
    await _pump(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    // 点中间 1/3 呼出工具栏。
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(ReaderPage),
      matchesGoldenFile('goldens/reader_toolbar.png'),
    );
  });

  testWidgets('阅读页-工具栏收起后必须完全移出屏幕', (tester) async {
    // 带刘海/Home 指示条的真机尺寸：工具栏如果在 SafeArea 里，收起时只会
    // 停在状态栏那条里（真机复现过），这里把它钉死。
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(_FakeTransport())),
          readerChapterCacheProvider.overrideWithValue(_PreviewChapterCache()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReaderPage(
            args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // 默认收起：顶部栏底边必须 <= 0，底部栏顶边必须 >= 屏幕高度。
    final topRect = tester.getRect(find.byType(ReaderTopBar));
    final bottomRect = tester.getRect(find.byType(ReaderBottomBar));
    expect(
      topRect.bottom,
      lessThanOrEqualTo(0.5),
      reason: '收起后顶部栏仍露出 ${topRect.bottom}pt',
    );
    expect(
      bottomRect.top,
      greaterThanOrEqualTo(873.5),
      reason: '收起后底部栏仍露出 ${874 - bottomRect.top}pt',
    );
  });

  testWidgets('阅读页-入口带 blockIndex 时恢复到对应页', (tester) async {
    // 假数据每章 18 段，第 9 段一定不在第 1 页。
    await _pump(
      tester,
      const ReaderPage(
        args: ReaderArgs(
          bookId: '1',
          bookTitle: '剑来',
          chapterId: 'c1',
          chapterIndex: 0,
          blockIndex: 9,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    final label = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .firstWhere(
          (data) => RegExp(r'^\d+/\d+$').hasMatch(data),
          orElse: () => '',
        );
    expect(label, isNotEmpty, reason: '底部信息条应显示页码');
    final currentPage = int.parse(label.split('/').first);
    expect(currentPage, greaterThan(1), reason: '带 blockIndex 进入不应落在第 1 页');
  });

  testWidgets('阅读页-切章有过渡且底栏章节名更新', (tester) async {
    await _pump(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
    );
    // 底栏初始显示第 1 章。
    expect(find.textContaining('第一章'), findsWidgets);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderPage)),
    );
    final args = const ReaderArgs(bookId: '1', bookTitle: '剑来');
    await container.read(readerSessionProvider(args).notifier).nextChapter();

    // 过渡中点：正文应该处于"未完成"状态（opacity < 1 或存在横向位移）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final transitions = tester
        .widgetList<FractionalTranslation>(find.byType(FractionalTranslation))
        .where((widget) => widget.translation.dx != 0)
        .toList();
    expect(transitions, isNotEmpty, reason: '切章应有一段横向过渡动画');

    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('第二章'), findsWidgets);
  });

  testWidgets('我的页（空书架）', (tester) async {
    await _pump(tester, const MinePage());
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_empty.png'),
    );
  });

  testWidgets('我的页（有书架与进度）', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        for (var i = 1; i <= 4; i++)
          {
            'id': '$i',
            'title': _FakeTransport._titles[i - 1],
            'cover': '',
            'author': '作者$i',
          },
      ]),
      'reading_progress_v1': jsonEncode({
        '1': {
          'bookId': '1',
          'bookTitle': '剑来',
          'cover': '',
          'chapterId': 'c3',
          'chapterIndex': 2,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
      }),
    });
    await _pump(tester, const MinePage());
    // 最近阅读（44 宽）和书架卡（_maxCardWidth 内）封面比例也必须统一。
    _expectCoverAspect(tester, '我的页');
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_shelf.png'),
    );
  });

  /// 首页里切到「我的」：验证悬浮切换按钮与悬浮底栏胶囊的相对位置（真机
  /// 是同一个 Scaffold 里叠加，单独 pump MinePage 看不到胶囊）。
  testWidgets('首页-我的（双面板与悬浮按钮）', (tester) async {
    await _pump(tester, const HomeShell());
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('小说'), findsWidgets);
    expect(find.byKey(MinePage.switchButtonKey), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/home_mine.png'),
    );
  });

  /// 悬浮按钮切换：小说面板滑出、短剧滑入，按钮图标同时换成另一侧。
  testWidgets('我的页-悬浮按钮切到短剧', (tester) async {
    await _pump(tester, const MinePage());

    // 初始：小说在屏幕内，按钮显示「短剧」图标（点它去看短剧）。
    expect(find.text('小说'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.theaters_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.text('短剧'), findsWidgets);
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    // 短剧标题块（延迟 0）已就位；小说标题整块滑到屏幕左侧外。
    expect(
      tester.getTopRight(find.text('短剧')).dx,
      closeTo(330, 1),
      reason: '短剧标题应停在镜像位置',
    );
    expect(tester.getTopLeft(find.text('小说')).dx, lessThan(-300));
    // 按钮换成「小说」图标。
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.auto_stories_rounded),
      ),
      findsOneWidget,
    );

    // 再点回小说。
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopLeft(find.text('小说')).dx, closeTo(60, 1));
    expect(find.text('我的书架'), findsOneWidget);
  });

  /// 左右滑动也能切换（类似阅读器翻页），不依赖悬浮按钮。
  testWidgets('我的页-左右滑动切换面板', (tester) async {
    await _pump(tester, const MinePage());

    // 往左滑 → 短剧。
    await tester.drag(find.byType(MinePage), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopRight(find.text('短剧')).dx, closeTo(330, 1));
    expect(
      find.descendant(
        of: find.byKey(MinePage.switchButtonKey),
        matching: find.byIcon(Icons.auto_stories_rounded),
      ),
      findsOneWidget,
    );

    // 往右滑 → 回小说。
    await tester.drag(find.byType(MinePage), const Offset(300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(tester.getTopLeft(find.text('小说')).dx, closeTo(60, 1));
  });

  /// 过渡不是整页一起动：标题块 0ms 先走，最近阅读块晚 100ms，书架块晚 200ms。
  testWidgets('我的页-三块阶梯延迟切换', (tester) async {
    // 需要有最近阅读内容，才能观察中间块（0ms）比标题块（100ms）先动。
    SharedPreferences.setMockInitialValues({
      'recent_reading_v1': jsonEncode([
        {
          'bookId': '1',
          'bookTitle': '剑来',
          'cover': '',
          'chapterId': 'c3',
          'chapterIndex': 2,
          'blockIndex': 0,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    });
    await _pump(tester, const MinePage());
    final headerBefore = tester.getTopLeft(find.text('小说')).dx;
    final recentBefore = tester.getTopLeft(find.text('最近阅读')).dx;
    final shelfBefore = tester.getTopLeft(find.text('我的书架')).dx;

    final gesture = await tester.startGesture(const Offset(200, 500));
    // 吃掉触摸 slop 后再精确拖 100px：时间轴走到约 0.26，
    // 最近阅读块（0ms）已滑走大半、标题块（100ms）刚起步、书架块（200ms）还没动。
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    final headerDelta =
        tester.getTopLeft(find.text('小说')).dx - headerBefore;
    final recentDelta =
        tester.getTopLeft(find.text('最近阅读')).dx - recentBefore;
    final shelfAfter = tester.getTopLeft(find.text('我的书架')).dx;
    expect(recentDelta, lessThan(-120), reason: '最近阅读块（0ms）应该先滑');
    expect(headerDelta, lessThan(0), reason: '标题块（100ms）随后开始');
    expect(
      headerDelta.abs(),
      lessThan(recentDelta.abs()),
      reason: '标题块应落后于最近阅读块',
    );
    expect(shelfAfter, closeTo(shelfBefore, 0.5), reason: '书架块（200ms）此时不应移动');

    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(find.text('短剧'), findsWidgets);
  });

  /// 短剧是镜像版式：标题/图标靠右；设置按钮只有一枚，随面板在屏幕内
  /// 从右侧滑到左侧，不再由两个面板各画一个。
  testWidgets('我的页-短剧标题与设置按钮左右镜像', (tester) async {
    await _pump(tester, const MinePage());
    const pageWidth = 390.0;
    const gutter = 16.0;
    const iconBox = 34.0;
    const iconGap = 10.0;

    expect(
      tester.getTopLeft(find.text('小说')).dx,
      closeTo(gutter + iconBox + iconGap, 1),
    );
    final settingsIcon = find.byIcon(Icons.settings_outlined);
    expect(settingsIcon, findsOneWidget, reason: '小说/短剧共用同一个设置按钮');
    expect(
      tester.getTopLeft(settingsIcon).dx,
      greaterThan(pageWidth / 2),
      reason: '小说的设置按钮在右侧',
    );

    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(
      tester.getTopRight(find.text('短剧')).dx,
      closeTo(pageWidth - (gutter + iconBox + iconGap), 1),
      reason: '短剧标题应与小说标题左右对称',
    );
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(
      tester.getTopLeft(settingsIcon).dx,
      lessThan(pageWidth / 2),
      reason: '同一个设置按钮应过渡到左侧',
    );
  });

  testWidgets('我的页（短剧）', (tester) async {
    await _pump(tester, const MinePage());
    await tester.tap(find.byKey(MinePage.switchButtonKey));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_drama_empty.png'),
    );
  });

  /// 过渡中：标题块已滑走大半、最近阅读块刚起步、书架块还没动（三块阶梯）。
  testWidgets('我的页-面板切换过程中', (tester) async {
    await _pump(tester, const MinePage());
    final gesture = await tester.startGesture(const Offset(200, 500));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    final settings = tester.getRect(find.byIcon(Icons.settings_outlined));
    expect(settings.left, greaterThanOrEqualTo(0), reason: '设置按钮不能被滑出屏幕');
    expect(settings.right, lessThanOrEqualTo(390), reason: '设置按钮不能被滑出屏幕');
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_switch_mid.png'),
    );
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
  });

  testWidgets('设置页', (tester) async {
    await _pump(tester, const SettingsPage());
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings.png'),
    );
  });

  testWidgets('设置页-自定义颜色弹层', (tester) async {
    await _pump(tester, const SettingsPage());
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    // 截整个屏幕（含遮罩与背后的设置页），只截 sheet 子树会丢掉上下文。
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_color_picker.png'),
    );
  });

  /// 换主题色必须「全站跟着变」：底色/按钮/选中态都由新的 seed 派生。
  testWidgets('设置页-绯红主题', (tester) async {
    SharedPreferences.setMockInitialValues({'app_seed_color_v1': 0xFFEF5350});
    await _pump(tester, const SettingsPage());
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_theme_red.png'),
    );
  });

  testWidgets('设置页-深色', (tester) async {
    await _pump(tester, const SettingsPage(), brightness: Brightness.dark);
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_dark.png'),
    );
  });

  /// 阅读弹层的主题作用域回归：弹层挂在 root Navigator 上，必须显式包一层
  /// 「纸色对应的 Theme」。否则暗色 App + 浅色纸底时，弹层里会用全局的亮色
  /// primary 画文字，在纸色上对比度只有 1.5:1（曾出现目录当前章看不清）。
  testWidgets('阅读页-设置弹层（暗色 App + 纸色底）', (tester) async {
    await _pump(
      tester,
      const ReaderPage(
        args: ReaderArgs(bookId: '1', bookTitle: '剑来'),
      ),
      brightness: Brightness.dark,
    );
    await tester.tapAt(const Offset(195, 420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final sheetContext = tester.element(find.byType(ReaderSettingsSheet));
    expect(
      Theme.of(sheetContext).colorScheme.brightness,
      Brightness.light,
      reason: '默认纸色是浅色，弹层应该用纸色的浅色 scheme，而不是全局暗色',
    );
    await expectLater(
      find.byType(ReaderSettingsSheet),
      matchesGoldenFile('goldens/reader_settings_sheet.png'),
    );
  });
}
