import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/rank.dart';
import 'package:novel_playlet/features/rank/rank_page.dart';
import 'package:novel_playlet/features/rank/rank_providers.dart';
import 'package:novel_playlet/features/rank/widgets/rank_preview_card.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/app/widgets/category_tab_bar.dart';
import 'package:novel_playlet/app/widgets/compact_card_row.dart';
import 'package:novel_playlet/app/widgets/surface_card.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/features/recommend/recommend_category.dart';

import 'preview_harness.dart';

RankCatalog _catalog() => const RankCatalog(
  rankId: '7098235271900037133',
  alias: '根据实时阅读热度排行',
  tabs: [
    RankTab(name: '漫剧榜', algo: 550),
    RankTab(name: '推荐榜', algo: 101),
    RankTab(name: '短剧榜', algo: 502),
  ],
);

RankEntry _book(int i) => RankEntry(
  position: i,
  kind: 'book',
  id: 'book-$i',
  title: '榜书$i',
  cover: '',
  author: '作者$i',
  abstract: '简介$i：唐诗三百首，两百忆盛唐，这是一段用于榜单页的两行简介。',
  category: '玄幻',
  score: '9.${9 - i}',
  heat: '${10 - i}000万热度',
  tags: const ['开局', '穿越'],
);

RankEntry _video(int i) => RankEntry(
  position: i,
  kind: 'video',
  id: 'video-$i',
  title: '短剧$i',
  cover: '',
  abstract: '短剧简介$i：大二学生陈北认清错误的恋爱关系后……',
  category: '逆袭',
  score: '8.${9 - i}',
  heat: '${10 - i}000万热度',
  episodeCount: 62,
  tags: const ['都市脑洞', '喜剧'],
);

Map<String, dynamic> _rankBoardPayload() => {
  'code': 0,
  'data': {
    'has_more': false,
    'cell_view': {
      'cell_alias': '根据阅读热度排行',
      'cell_data': [
        for (var i = 1; i <= 3; i++)
          {
            'book_data': [
              {
                'book_id': 'book-$i',
                'book_name': '榜书$i',
                'author': '作者$i',
                'abstract': '简介$i',
                'pure_category_tags': '玄幻',
                'score': '9.${9 - i}',
                'rank_score': '${10 - i}000万热度',
              },
            ],
          },
      ],
    },
  },
};

/// 短剧/漫剧榜的回包：`video_data` + `genre_tab=4/5` 时上游按视频条目回答。
Map<String, dynamic> _rankVideoBoardPayload() => {
  'code': 0,
  'data': {
    'has_more': false,
    'cell_view': {
      'cell_alias': '根据播放热度排行',
      'cell_data': [
        for (var i = 1; i <= 12; i++)
          {
            'video_data': [
              {
                'series_id': 'video-$i',
                'title': '短剧$i',
                'cover': '',
                'episode_cnt': 60 + i,
                'score': '8.${9 - i % 9}',
                'secondary_info_list': [
                  {'data_type': 3, 'content': '逆袭'},
                  {'data_type': 2, 'content': '${10 - i % 9}000万热度'},
                ],
              },
            ],
          },
      ],
    },
  },
};

void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  testWidgets('排行榜-目录顺序、initialAlgo 自动定位、条目字段与标签', (tester) async {
    final calls = <String>[];
    await pumpPreview(
      tester,
      RankPage(
        initialAlgo: 502,
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls.add('${tab.algo}@$offset');
              return RankBoard(
                alias: '榜单基于观看量、互动及个人兴趣排序',
                entries: [_video(1), _video(2), _video(3)],
              );
            },
      ),
    );

    // 目录按小说 → 短剧 → 漫剧重排；没有 101 时 101 仍排最前。
    final x101 = tester
        .getTopLeft(find.byKey(const ValueKey('rank_tab_101')))
        .dx;
    final x502 = tester
        .getTopLeft(find.byKey(const ValueKey('rank_tab_502')))
        .dx;
    final x550 = tester
        .getTopLeft(find.byKey(const ValueKey('rank_tab_550')))
        .dx;
    expect(x101 < x502, isTrue);
    expect(x502 < x550, isTrue);

    // initialAlgo=502：落地即拉短剧榜，并选中对应 tab。
    expect(calls, ['502@0']);
    final scheme = Theme.of(tester.element(find.byType(RankPage))).colorScheme;
    final selectedTab = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('rank_tab_502')),
        matching: find.text('短剧榜'),
      ),
    );
    expect(selectedTab.style?.color, scheme.primary);
    expect(selectedTab.style?.fontWeight, FontWeight.w700);

    // 条目：名次、标题、评分、元信息（分类 · 全 N 集 · 热度）、简介、标签。
    expect(find.text('短剧1'), findsOneWidget);
    expect(find.text('8.8分'), findsOneWidget);
    expect(find.text('逆袭 · 全62集 · 9000万热度'), findsOneWidget);
    expect(find.textContaining('短剧简介1'), findsOneWidget);
    expect(find.text('都市脑洞'), findsWidgets);
    expect(find.text('没有更多了'), findsOneWidget, reason: '底部文案与首页流一致');
    expect(tester.widget<Text>(find.text('1')).style?.color, scheme.error);
  });

  testWidgets('排行榜-切 tab 重新拉对应榜，小说榜展示作者与简介', (tester) async {
    final calls = <String>[];
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls.add('${tab.algo}@$offset');
              return RankBoard(
                alias: tab.genreTab == 2 ? '根据阅读热度排行' : '',
                entries: tab.genreTab == 2 ? [_book(1), _book(2)] : [_video(1)],
              );
            },
      ),
    );

    expect(calls, ['101@0']);
    expect(find.text('榜书1'), findsOneWidget);
    expect(find.text('作者1 · 玄幻 · 9000万热度'), findsOneWidget);
    expect(find.textContaining('简介1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rank_tab_502')));
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '502@0']);
    expect(find.text('短剧1'), findsOneWidget);
    expect(find.text('榜书1'), findsNothing);
  });

  testWidgets('排行榜-已请求 tab 切走再回来不重复拉数据', (tester) async {
    final calls = <String>[];
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls.add('${tab.algo}@$offset');
              return RankBoard(
                entries: tab.genreTab == 2 ? [_book(1)] : [_video(1)],
              );
            },
      ),
    );
    expect(calls, ['101@0']);
    expect(find.text('榜书1'), findsOneWidget);

    await tester.fling(
      find.byKey(const Key('rank_pages')),
      const Offset(-320, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '502@0']);
    expect(find.text('短剧1'), findsOneWidget);

    await tester.fling(
      find.byKey(const Key('rank_pages')),
      const Offset(320, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '502@0'], reason: '切回已请求过的榜不能重拉');
    expect(find.text('榜书1'), findsOneWidget);
  });

  testWidgets('首页榜单预览卡-标题在卡片外、只铺前十、可左右滑', (tester) async {
    final data = RankPreviewData(
      tab: const RankTab(name: '推荐榜', algo: 101),
      board: RankBoard(entries: [for (var i = 1; i <= 12; i++) _book(i)]),
    );
    await pumpPreview(
      tester,
      Scaffold(
        body: RankPreviewCardView(
          data: data,
          category: RecommendCategory.novel,
        ),
      ),
    );

    // 版式与搜索结果页一致：榜名在卡片外面，下面是同款紧凑卡。
    expect(find.text('推荐榜'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('推荐榜'),
        matching: find.byType(AppSurfaceCard),
      ),
      findsNothing,
      reason: '榜名在卡片外面，不再包在白色卡片里',
    );
    final firstCard = find.byType(NovelGridCard).first;
    expect(
      tester.getTopLeft(find.text('推荐榜')).dy,
      lessThan(tester.getTopLeft(firstCard).dy),
      reason: '榜名在卡片上方',
    );
    // 一屏 3.5 张的卡宽口径（与搜索结果同一套）。
    expect(
      tester.getSize(firstCard).width,
      closeTo(CompactCardRow.cardWidthFor(390), 0.01),
    );
    // 只预览前十（上游一页 12 条也截到 10）。
    for (var i = 1; i <= 10; i++) {
      expect(find.text('榜书$i'), findsOneWidget, reason: '缺少第 $i 条');
    }
    expect(find.text('榜书11'), findsNothing);
    expect(find.text('榜书12'), findsNothing);
    // 卡面元信息与搜索卡一致：作者一行、热度单独一行，分类不再挤进来。
    expect(find.text('作者1'), findsOneWidget);
    expect(find.text('9000万热度'), findsOneWidget);
    expect(find.text('作者1 · 玄幻 · 9000万热度'), findsNothing);
    // 首页卡片不再带 1/2/3 名次标号。
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);

    // 十张卡超出一屏：这一行可以左右滑。
    final scrollFinder = find.byType(SingleChildScrollView);
    expect(scrollFinder, findsOneWidget);
    expect(
      tester.widget<SingleChildScrollView>(scrollFinder).scrollDirection,
      Axis.horizontal,
    );
    final before = tester.getTopLeft(firstCard).dx;
    await tester.drag(scrollFinder, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(firstCard).dx,
      lessThan(before),
      reason: '榜单卡行必须能左右滑动',
    );
  });

  testWidgets('推荐页-首次进入榜单未回来时先显示骨架卡', (tester) async {
    final fake = FakePreviewTransport()
      ..rankBoardDelay = const Duration(milliseconds: 300)
      ..rankBoardPayload = _rankBoardPayload();
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: fake,
      rankCatalog: _catalog(),
      settle: false,
    );
    // 推荐流先回来、榜单还在延迟中：卡片位置先显示同高骨架。
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const Key('rank_preview_skeleton')),
      findsOneWidget,
      reason: '第一次进 tab 时榜单还没回来，应显示同高骨架而不是整块消失',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('rank_preview_skeleton')), findsNothing);
    expect(find.text('榜书1'), findsOneWidget);
  });

  testWidgets('排行榜-内容区左右滑切换 tab', (tester) async {
    final calls = <String>[];
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls.add('${tab.algo}@$offset');
              return RankBoard(entries: [_book(1)]);
            },
      ),
    );
    expect(calls, ['101@0']);

    await tester.fling(
      find.byKey(const Key('rank_pages')),
      const Offset(-320, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '502@0']);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('rank_tab_502'))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('rank_tab_550'))).dx,
      ),
    );
  });

  testWidgets('推荐页-榜单卡片在瀑布流上方，标题/更多/前三预览', (tester) async {
    final fake = FakePreviewTransport()..rankBoardPayload = _rankBoardPayload();
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: fake,
      rankCatalog: _catalog(),
    );

    expect(find.byType(RankPreviewCard), findsOneWidget);
    expect(find.text('推荐榜'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('榜书1'), findsOneWidget);
    expect(find.text('榜书2'), findsOneWidget);
    expect(find.text('榜书3'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(RankPreviewCardView)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('剑来')).dy),
      reason: '榜单区块应在推荐瀑布流上方',
    );
    // tabs 的下划线贴行底：下划线到榜单卡片留 8pt，不贴着卡片。
    final bar = tester.getRect(find.byType(CategoryTabBar));
    final card = tester.getRect(find.byType(RankPreviewCardView));
    expect(
      card.top - bar.bottom,
      closeTo(8, 0.5),
      reason: '下划线到榜单卡片留 8pt，实际 ${card.top - bar.bottom}',
    );

    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.byType(RankPage), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('推荐页-短剧/漫剧 tab 也有各自的榜单区块', (tester) async {
    final fake = FakePreviewTransport()
      ..rankBoardPayload = _rankVideoBoardPayload();
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: fake,
      rankCatalog: _catalog(),
    );
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('短剧榜'), findsOneWidget, reason: '短剧 tab 要有短剧榜');
    expect(find.text('短剧1'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);

    await tester.tap(find.text('漫剧'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('漫剧榜'), findsOneWidget, reason: '漫剧 tab 要有漫剧榜');
    expect(find.text('短剧1'), findsOneWidget);
  });

  testWidgets('排行榜-首屏不满一屏自动补页，触底翻页后到底', (tester) async {
    final calls = <String>[];
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls.add('${tab.algo}@$offset');
              if (offset == 0) {
                return RankBoard(
                  hasMore: true,
                  nextOffset: 3,
                  entries: [_book(1), _book(2), _book(3)],
                );
              }
              return RankBoard(entries: [_book(4)]);
            },
      ),
    );
    // 3 行填不满一屏：FeedView 首帧后自动补下一页（以前排行榜页没有这个兜底）。
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '101@3']);
    expect(find.text('榜书4'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);

    // 已经到底：继续下滑不会再发请求。
    await tester.drag(find.text('榜书1'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(calls, ['101@0', '101@3']);
  });

  testWidgets('排行榜-翻页失败在底部给重试', (tester) async {
    var requested = 0;
    var failures = 0;
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              requested = offset;
              if (offset == 0) {
                return RankBoard(
                  hasMore: true,
                  nextOffset: 2,
                  entries: [_book(1), _book(2)],
                );
              }
              failures++;
              if (failures == 1) throw StateError('offline');
              return RankBoard(entries: [_book(3)]);
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('榜书3'), findsOneWidget);
    expect(requested, 2);
  });

  testWidgets('排行榜-接口失败显示错误并重试', (tester) async {
    var attempts = 0;
    await pumpPreview(
      tester,
      RankPage(
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              attempts++;
              if (attempts == 1) throw StateError('offline');
              return RankBoard(entries: [_book(1)]);
            },
      ),
    );

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('榜书1'), findsOneWidget);
  });
}
