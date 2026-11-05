import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/feed/feed_results.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/shell/home_shell.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/cache/app_cache.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/features/mine/mine_providers.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_widgets.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
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

  /// 每次请求的延迟；只有需要观察中间 loading 态的单测才设置。
  Duration responseDelay = Duration.zero;

  /// 小说推荐流的卡片数；滚动保活测试需要多屏内容。
  int novelItemCount = 9;

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
    if (path.startsWith('/api/v1/search') &&
        failingQueries.any(keyword.contains)) {
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
                                'series_title': _dramaTitles[(i - 1) % _dramaTitles.length],
                                'series_cover': '',
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
                                'thumb_url': '',
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
      // 搜索接口的 tab_type 与首页流不同：3 = 书籍、11 = 短剧、8 = 漫画。
      switch (params['tab_type']) {
        case '11':
          return _videoSearchPayload(11, [
            for (var i = 1; i <= 6; i++)
              {
                'series_id_str': 'vs$i',
                'series_title':
                    '搜索结果 ${_dramaTitles[(i - 1) % _dramaTitles.length]}',
                'series_intro':
                    '这是第 $i 条短剧搜索结果的简介，用来验证横向列表两行省略与排版是否和小说搜索一致。',
                'episode_cnt': '${40 + i}',
                'series_cover': '',
              },
          ]);
        case '8':
          return _videoSearchPayload(8, [
            for (var i = 1; i <= 6; i++)
              {
                'pseries_id': 'as$i',
                'series_name':
                    '漫剧搜索 ${_animeTitles[(i - 1) % _animeTitles.length]}',
                'series_intro':
                    '这是第 $i 条漫剧搜索结果的简介，用来验证横向列表两行省略与排版。',
                'episode_cnt': '${12 + i * 2}',
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
                    for (var i = 1; i <= 6; i++)
                      {
                        'book_data': {
                          'book_id': 's$i',
                          'book_name':
                              '搜索结果 ${_titles[(i - 1) % _titles.length]}',
                          'author': '作者$i',
                          'abstract':
                              '这是第 $i 条搜索结果的简介，用来验证两行省略与排版。',
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
        },
      };
    }
    if (path.endsWith('/directory')) {
      return {
        'code': 0,
        'data': {
          'item_data_list': [
            for (var i = 1; i <= 24; i++)
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

ThemeData _previewTheme() {
  final base = AppTheme.light();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _previewFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: _previewFontFamily,
    ),
  );
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
        cacheUsageProvider.overrideWith(
          (ref) async => _previewCacheUsage,
        ),
        if (store != null) readingStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        theme: _previewTheme(),
        debugShowCheckedModeBanner: false,
        // 页面本身依赖外层 Scaffold 提供 Material（HomeShell 里有），
        // 预览时补一个，保证 InkWell / 文本选择等祖先齐全。
        home: Scaffold(body: page),
      ),
    ),
  );
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
    expect(find.byType(NavigationDestination), findsNWidgets(2));
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    // 合并后底部只剩「推荐 / 我的」，分类在搜索框下方的 tabs 里。
    expect(find.text('小说'), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/home.png'),
    );

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(MinePage), findsOneWidget);
  });

  /// 当前可见竖向列表的滚动偏移（跳过 PageView 的横向 Scrollable）。
  double verticalOffset(WidgetTester tester) {
    final finder = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    return tester.state<ScrollableState>(finder.first).position.pixels;
  }

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
    expect(
      countOf('/api/v1/search'),
      searchCalls,
      reason: '取消搜索只回显快照，不应再发请求',
    );
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
}
