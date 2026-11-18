import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/widgets/card_flight_route.dart';
import 'package:novel_playlet/app/widgets/novel_card.dart';
import 'package:novel_playlet/features/detail/detail_page.dart';
import 'package:novel_playlet/features/recommend/recommend_page.dart';
import 'package:novel_playlet/features/video/video_detail_page.dart';
import 'package:novel_playlet/features/video/widgets/video_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 详情页的「两段式容器变换」转场（[CardFlightRoute]）。
///
/// 0–50%：卡片快照等比放大到屏宽 75%，详情页不可见。
/// 50–100%：封面/标题/作者/评分飞到详情页对应位置，页面内容同步淡入。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openFirstDetail(WidgetTester tester) async {
    await tester.tap(find.byType(NovelGridCard).first);
    // 第一帧装路由、第二帧才建出页面；不推进时间，转场仍在 t=0。
    await tester.pump();
    await tester.pump();
  }

  Rect screenRect(WidgetTester tester) =>
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;

  /// 详情页当前的透明度（转场里包在页面外面的那层 Opacity）。
  double pageOpacity(WidgetTester tester) =>
      tester.widget<Opacity>(find.byKey(pageOpacityKey)).opacity;

  testWidgets('进入详情：第一段详情页不可见，第二段才淡入', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    final cardRect = tester.getRect(find.byType(NovelGridCard).first);

    await openFirstDetail(tester);
    final route = ModalRoute.of(tester.element(find.byType(DetailPage)));
    expect(route, isA<CardFlightRoute<void>>());
    expect(
      (route! as CardFlightRoute<void>).data?.rect.call(),
      cardRect,
      reason: '路由要拿到「就是这张卡片」的矩形当快照起点',
    );
    expect(pageOpacity(tester), 0, reason: '第一段只看卡片快照，页面不能露出来');

    // 走到第一段结束附近（520ms 的一半略后）：页面开始淡入。
    await tester.pump(const Duration(milliseconds: 300));
    expect(pageOpacity(tester), greaterThan(0), reason: '第二段页面要跟着元素飞行一起淡入');

    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    // 转场结束后飞行层整体撤掉（页面直接铺满，不再包透明度层）。
    expect(find.byKey(pageOpacityKey), findsNothing);
    expect(tester.getRect(find.byType(DetailPage)), screenRect(tester));
  });

  testWidgets('第一段：卡片快照等比放大，比例不变', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );

    /// 快照外层的缩放矩阵：等比缩放 = x/y 两个方向同一个倍率。
    ({double scale, bool uniform}) cloneScale() {
      final t = tester.widget<Transform>(find.byKey(cardCloneKey));
      final storage = t.transform.storage;
      return (
        scale: storage[0],
        uniform: (storage[0] - storage[5]).abs() < 0.001,
      );
    }

    await openFirstDetail(tester);
    await tester.pump(const Duration(milliseconds: 60));
    final first = cloneScale();
    await tester.pump(const Duration(milliseconds: 140));
    final second = cloneScale();

    expect(first.uniform, isTrue, reason: '第一段只能等比放大（x/y 倍率相同）');
    expect(second.uniform, isTrue);
    expect(second.scale, greaterThan(first.scale), reason: '第一段卡片快照要一直在放大');
    expect(
      second.scale,
      lessThanOrEqualTo(1.7),
      reason: '第一段上限约屏宽 75%（卡片约占半屏宽，放大倍率约 1.6）',
    );

    // 第二段开始后快照淡出，交给飞行元素。
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(cardCloneKey), findsNothing);
  });

  testWidgets('边缘侧滑返回：拖动驱动反向，松手后 route 被 pop', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    await openFirstDetail(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final gesture = await tester.startGesture(const Offset(8, 400));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(240, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(DetailPage), findsNothing);
  });

  testWidgets('侧滑距离不够：回弹，不返回', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    await openFirstDetail(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    final gesture = await tester.startGesture(const Offset(8, 400));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(DetailPage), findsOneWidget);
  });

  testWidgets('转场期间下层列表不做视差位移，结束后开关复位', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    expect(cardExpandTransitionsActive.value, 0);
    final cardRect = tester.getRect(find.byType(NovelGridCard).first);
    await openFirstDetail(tester);
    expect(cardExpandTransitionsActive.value, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byType(NovelGridCard).first), cardRect);

    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(cardExpandTransitionsActive.value, 0);

    Navigator.of(tester.element(find.byType(DetailPage))).pop();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(cardExpandTransitionsActive.value, 0);
  });

  testWidgets('短剧详情同样走两段式转场', (tester) async {
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    await tester.tap(find.text('短剧'));
    await tester.pumpAndSettle();
    final cardRect = tester.getRect(find.byType(VideoCard).first);
    await tester.tap(find.byType(VideoCard).first);
    await tester.pump();
    await tester.pump();

    expect(find.byType(VideoDetailPage), findsOneWidget);
    final route = ModalRoute.of(tester.element(find.byType(VideoDetailPage)));
    expect(route, isA<CardFlightRoute<void>>());
    expect((route! as CardFlightRoute<void>).data?.rect.call(), cardRect);
  });

  testWidgets('减弱动态效果：不做容器变换，直接按全屏布局', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpPreview(
      tester,
      const RecommendPage(),
      transport: FakePreviewTransport(),
      platform: TargetPlatform.iOS,
    );
    await openFirstDetail(tester);
    expect(tester.getRect(find.byType(DetailPage)), screenRect(tester));
  });
}
