import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/cover_hero.dart';

/// [revealHeroSource]：点卡片进详情前，先把卡片整块移进「内容可视区」。
///
/// 背景：Hero 飞行层在 Navigator 的 Overlay 最上层，卡片被滚出视口、或被悬浮
/// 底栏压住一部分时，封面起飞/落位都会画在这些固定元素上面。这里的断言都是
/// 「滚了多少」这类确定性数字：顶部固定区 100pt、视口 500pt、卡片高 100pt、
/// 底栏占底部 80pt（即可见底边在视口内 420pt 处）。
void main() {
  const bottomInset = 80.0;

  /// 顶部固定 100pt + 一条 20 张、每张 100pt 的可滚动列表。
  Future<ScrollController> pumpList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 100),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: 20,
                  itemBuilder: (context, index) {
                    return SizedBox(key: Key('card-$index'), height: 100);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('已经完整可见：不动列表', (tester) async {
    final controller = await pumpList(tester);
    // 第 2 张卡在视口内 [100,200]，离底栏还远。
    revealHeroSource(
      tester.element(find.byKey(const Key('card-1'))),
      bottomInset: bottomInset,
    );
    expect(controller.offset, 0);
  });

  testWidgets('卡片压在底栏下面：往上滚到完整露出', (tester) async {
    final controller = await pumpList(tester);
    // 第 5 张卡在视口内 [400,500]，可见底边只到 420，被压住 80pt。
    revealHeroSource(
      tester.element(find.byKey(const Key('card-4'))),
      bottomInset: bottomInset,
    );
    await tester.pump();
    expect(controller.offset, 80);
    // 滚完这一张落在 [420,520]：底边正好贴上胶囊顶边（100 顶部固定区 + 420 可见底边）。
    final rect = tester.getRect(find.byKey(const Key('card-4')));
    expect(rect.top, 420);
    expect(rect.bottom, 520);
  });

  testWidgets('卡片被滚到视口上方：往下滚回来', (tester) async {
    final controller = await pumpList(tester);
    controller.jumpTo(80);
    await tester.pump();
    // 第 1 张卡在视口内 [-80,20]，顶部被滚出去 80pt。
    revealHeroSource(
      tester.element(find.byKey(const Key('card-0'))),
      bottomInset: bottomInset,
    );
    await tester.pump();
    expect(controller.offset, 0);
  });
}
