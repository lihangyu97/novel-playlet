import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/app/widgets/novel_cover.dart';
import 'package:novel_playlet/data/models/novel_item.dart';
import 'package:novel_playlet/features/feed/feed_staggered_grid.dart';

import 'preview_harness.dart';

/// 瀑布流布局本身：卡片不定高时按列自上而下排、双列/三列切换。
///
/// 不看真实数据：假数据里把标题长短、有没有元信息都覆盖到，避免以后卡片
/// 内容变化时"瀑布流退化成等高网格"没人发现。
///
/// 更新基线：`flutter test --update-goldens test/ui/feed_staggered_grid_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  const items = [
    NovelItem(id: '1', title: '剑来', author: '烽火戏诸侯', score: '9.3'),
    NovelItem(id: '2', title: '一个明显会折成两行的很长很长的书名', author: '爱潜水的乌贼'),
    NovelItem(id: '3', title: '大奉打更人', author: '卖报小郎君', score: '8.8'),
    NovelItem(id: '4', title: '夜的命名术', author: '会说话的肘子'),
    NovelItem(id: '5', title: '赤心巡天', author: '情何以甚'),
    NovelItem(id: '6', title: '完美世界', author: '辰东', score: '9.3'),
  ];

  /// 只放瀑布流本身（不套 RecommendPage）：页面骨架会引入搜索框/tabs/网络
  /// 假数据，这里要验证的是「卡片不定高时怎么排」。
  Widget gridPage(int columns) {
    return CustomScrollView(
      slivers: [
        FeedStaggeredGrid<NovelItem>(
          items: items,
          columns: columns,
          itemBuilder: (context, item, width) => NovelGridCard(
            key: ValueKey(item.id),
            item: item,
            width: width,
            onTap: () {},
            showRecommendMeta: true,
            surface: true,
            naturalTitleHeight: true,
            coverAspect: kNovelCoverAspect,
          ),
        ),
      ],
    );
  }

  /// 卡片实际布局矩形，按 widget 顺序（= 数据顺序）。
  List<Rect> cardRects(WidgetTester tester) {
    return tester
        .widgetList<NovelGridCard>(find.byType(NovelGridCard))
        .map((card) => tester.getRect(find.byWidget(card)))
        .toList();
  }

  testWidgets('瀑布流-双列不定高卡片按列排，列宽一致', (tester) async {
    await pumpPreview(tester, gridPage(2));

    final rects = cardRects(tester);
    // 瀑布流按需构建，只断言已布局的卡片数量足够做分列判断。
    expect(rects.length, greaterThanOrEqualTo(4));
    expect(
      rects.map((rect) => rect.left).toSet(),
      hasLength(2),
      reason: '双列：卡片左边距只有两种',
    );
    // 用「列间距」反查真实布局：只断言尺寸集合相等是恒真的（masonry
    // 给的是紧宽度约束），间距错了才会真的暴露出 MediaQuery 与 sliver
    // 约束不一致的问题。
    expect(
      rects[1].left - rects[0].right,
      closeTo(FeedStaggeredGrid.crossAxisSpacing, 0.5),
      reason: '两列之间的间距',
    );
    expect(
      rects.map((rect) => rect.height).toSet().length,
      greaterThan(1),
      reason: '标题 1/2 行不同，卡片高度必须由内容决定',
    );
    // 瀑布流：同列第二张卡贴在前一张下面，不会被另一列撑高后留空。
    final leftColumn = rects
        .where((rect) => rect.left == rects.first.left)
        .toList();
    expect(leftColumn.length, greaterThan(1));
    expect(
      leftColumn[1].top,
      closeTo(leftColumn[0].bottom + FeedStaggeredGrid.mainAxisSpacing, 0.5),
      reason: '同列卡片按行间距紧接排列',
    );

    await expectLater(
      find.byType(CustomScrollView),
      matchesGoldenFile('../goldens/feed_staggered_grid.png'),
    );
  });

  testWidgets('瀑布流-三列', (tester) async {
    await pumpPreview(tester, gridPage(3));

    final rects = cardRects(tester);
    expect(
      rects.map((rect) => rect.left).toSet(),
      hasLength(3),
      reason: '三列：卡片左边距有三种',
    );
    // 三列时卡宽 = (390 - 16*2 - 12*2) / 3。
    expect(
      rects.first.width,
      closeTo((390 - 32 - FeedStaggeredGrid.crossAxisSpacing * 2) / 3, 0.5),
    );
  });
}
