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
    expect(find.text('已经到底了'), findsOneWidget);
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

  testWidgets('首页榜单预览卡-标题/更多/只铺前三', (tester) async {
    final data = RankPreviewData(
      tab: const RankTab(name: '推荐榜', algo: 101),
      board: RankBoard(entries: [_book(1), _book(2), _book(3), _book(4)]),
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
    expect(find.text('榜书1'), findsOneWidget);
    expect(find.text('榜书2'), findsOneWidget);
    expect(find.text('榜书3'), findsOneWidget);
    expect(find.text('榜书4'), findsNothing, reason: '只预览前三条');
    // 卡面元信息与搜索卡一致：作者一行、热度单独一行，分类不再挤进来。
    expect(find.text('作者1'), findsOneWidget);
    expect(find.text('9000万热度'), findsOneWidget);
    expect(find.text('作者1 · 玄幻 · 9000万热度'), findsNothing);
    // 首页卡片不再带 1/2/3 名次标号。
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
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
