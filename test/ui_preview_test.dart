import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/core/storage/reading_store.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:novel_playlet/data/models/chapter_content.dart';
import 'package:novel_playlet/features/reader/reader_chapter_cache.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';
import 'package:novel_playlet/features/reader/reader_widgets.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI 预览：用假 transport 注入固定上游数据，把四个页面真实渲染成 PNG。
///
/// 目的不是断言像素，而是让 Lead 在没有模拟器/真机的环境里也能看到真实
/// 布局。更新基线：`flutter test --update-goldens test/ui_preview_test.dart`
///
/// 顺带说明：封面 URL 故意留空，避免 widget 测试里真的发网络请求。
class _FakeTransport extends BackendTransport {
  _FakeTransport() : super(port: 0);

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async {
    return BackendResponse(
      200,
      Uint8List.fromList(utf8.encode(jsonEncode(_payloadFor(path)))),
      'application/json',
    );
  }

  Map<String, dynamic> _payloadFor(String path) {
    if (path.startsWith('/api/v1/recommend/homepage')) {
      // 与真实响应同形：游标/session 挂在被回答的 tab_item 上，
      // 卡片藏在 tab.cell_data[].cell_data[].book_data[] 里。
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
                        for (var i = 1; i <= 9; i++)
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
    if (path.startsWith('/api/v1/search')) {
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
                      'book_name': '搜索结果 ${_titles[(i - 1) % _titles.length]}',
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
  static const _chapterNames = ['山中有剑', '少年游', '问心', '风雪夜归人', '青衫仗剑'];
  static const _paragraphs = [
    '大千世界，无奇不有。',
    '陈平安抬头看了一眼天色，背起竹篓往山上走。',
    '山风穿过松林，带着一股凉意。',
  ];

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

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  ReadingStore? store,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = ApiClient(_FakeTransport());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        readerChapterCacheProvider.overrideWithValue(_PreviewChapterCache()),
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

void main() {
  setUpAll(() async {
    await _loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('推荐页', (tester) async {
    await _pump(tester, const RecommendPage());
    await expectLater(
      find.byType(RecommendPage),
      matchesGoldenFile('goldens/recommend.png'),
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
      const ReaderPage(args: ReaderArgs(bookId: '1', bookTitle: '剑来')),
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
    await expectLater(
      find.byType(MinePage),
      matchesGoldenFile('goldens/mine_shelf.png'),
    );
  });
}
