import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/data/models/rank.dart';
import 'package:novel_playlet/features/rank/rank_cache.dart';
import 'package:novel_playlet/features/rank/rank_page.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';

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

/// 短剧/漫剧榜的回包：`video_data` + `genre_tab=4/5` 时上游按视频条目回答。
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

  testWidgets('推荐页-左上角排行榜入口打开排行榜页', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
    );
    expect(find.byTooltip('搜索'), findsOneWidget);
    await tester.tap(find.byTooltip('排行榜'));
    await tester.pumpAndSettle();
    expect(find.byType(RankPage), findsOneWidget);
  });

  /// iOS 的左边缘侧滑返回由 `PageTransitionsTheme` 里的
  /// `CupertinoPageTransitionsBuilder` 装手势。`RankRoute` 曾经改成自定义
  /// `PageRouteBuilder` 做「左滑入场」，绕过了主题，侧滑返回就没了。
  testWidgets('推荐页-排行榜支持 iOS 左边缘侧滑返回', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      platform: TargetPlatform.iOS,
      transport: FakePreviewTransport(),
      rankCatalog: _catalog(),
    );
    await tester.tap(find.byTooltip('排行榜'));
    await tester.pumpAndSettle();
    expect(find.byType(RankPage), findsOneWidget);

    // 从屏幕左边缘往右拖，触发 iOS 的交互式返回手势。
    await tester.dragFrom(const Offset(2, 400), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(find.byType(RankPage), findsNothing, reason: '侧滑应退出排行榜');
    expect(find.byType(RecommendPage), findsOneWidget, reason: '应回到推荐页');
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

  testWidgets('排行榜-命中预取缓存先渲染，不发首屏请求', (tester) async {
    final cache = RankBoardCache();
    cache.write(
      const RankBoardCacheKey(
        rankId: '7098235271900037133',
        algo: 101,
        genreTab: 2,
      ),
      RankBoard(entries: [_book(1)]),
    );
    var calls = 0;
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
              calls++;
              return RankBoard(entries: [_book(2)]);
            },
      ),
      extraOverrides: [rankBoardCacheProvider.overrideWithValue(cache)],
    );
    await tester.pumpAndSettle();

    expect(find.text('榜书1'), findsOneWidget);
    expect(find.text('榜书2'), findsNothing);
    expect(calls, 0, reason: '缓存新鲜时首屏不发请求');
  });

  testWidgets('排行榜-短剧命中预热缓存不发首屏请求', (tester) async {
    final cache = RankBoardCache();
    cache.write(
      const RankBoardCacheKey(
        rankId: '7098235271900037133',
        algo: 502,
        genreTab: 4,
      ),
      RankBoard(entries: [_book(2)]),
    );
    var calls = 0;
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
              calls++;
              return RankBoard(entries: [_book(9)]);
            },
      ),
      extraOverrides: [rankBoardCacheProvider.overrideWithValue(cache)],
    );
    await tester.pumpAndSettle();

    expect(find.text('榜书2'), findsOneWidget);
    expect(calls, 0, reason: '短剧榜命中缓存时首屏不发请求');
  });

  testWidgets('排行榜-漫剧命中预热缓存不发首屏请求', (tester) async {
    final cache = RankBoardCache();
    cache.write(
      const RankBoardCacheKey(
        rankId: '7098235271900037133',
        algo: 550,
        genreTab: 5,
      ),
      RankBoard(entries: [_book(3)]),
    );
    var calls = 0;
    await pumpPreview(
      tester,
      RankPage(
        initialAlgo: 550,
        catalogLoader: () async => _catalog(),
        pageLoader:
            ({
              required rankId,
              required tab,
              required offset,
              required startAt,
            }) async {
              calls++;
              return RankBoard(entries: [_book(9)]);
            },
      ),
      extraOverrides: [rankBoardCacheProvider.overrideWithValue(cache)],
    );
    await tester.pumpAndSettle();

    expect(find.text('榜书3'), findsOneWidget);
    expect(calls, 0, reason: '漫剧榜命中缓存时首屏不发请求');
  });

  testWidgets('排行榜-预热缓存晚到会替换 loading，网络结果再替换缓存', (tester) async {
    final cache = RankBoardCache();
    final boardFuture = Completer<RankBoard>();
    await pumpPreview(
      tester,
      RankPage(
        initialAlgo: 502,
        catalogLoader: () async => _catalog(),
        pageLoader: ({
          required rankId,
          required tab,
          required offset,
          required startAt,
        }) => boardFuture.future,
      ),
      extraOverrides: [rankBoardCacheProvider.overrideWithValue(cache)],
      settle: false,
    );
    await tester.pump();
    expect(find.textContaining('正在加载榜单'), findsOneWidget);

    // 模拟预热请求在页面首屏请求之后才返回。
    cache.write(
      const RankBoardCacheKey(
        rankId: '7098235271900037133',
        algo: 502,
        genreTab: 4,
      ),
      RankBoard(entries: [_book(4)]),
    );
    await tester.pump();
    expect(find.text('榜书4'), findsOneWidget);
    expect(find.textContaining('正在加载榜单'), findsNothing);

    boardFuture.complete(RankBoard(entries: [_book(9)]));
    await tester.pumpAndSettle();
    expect(find.text('榜书9'), findsOneWidget);
  });
}
