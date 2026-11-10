import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/shell/floating_navigation_bar.dart';
import 'package:novel_playlet/app/shell/home_shell.dart';
import 'package:novel_playlet/features/feed/feed_search_field.dart';
import 'package:novel_playlet/features/mine/mine_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_harness.dart';

/// 首页壳预览：推荐/我的两个底部 tab、滚动保活、跨页 Hero tag 唯一性。
///
/// 更新基线：`flutter test --update-goldens test/ui/home_test.dart`。
void main() {
  setUpAll(() async {
    await loadPreviewFont();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('推荐页与书架同书共存时 Hero tag 不冲突', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shelf_books_v1': jsonEncode([
        {'id': '1', 'title': '剑来', 'cover': '', 'author': '作者1'},
      ]),
    });
    await pumpPreview(tester, const HomeShell());
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

  testWidgets('首页-推荐/我的两个底部 tab', (tester) async {
    await pumpPreview(tester, const HomeShell());
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
      matchesGoldenFile('../goldens/home.png'),
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
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const HomeShell(), transport: fake);
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

  /// 底栏「推荐」处于选中态时再次点击：当前分类列表平滑回顶（不是瞬移）。
  testWidgets('首页-再次点击底栏「推荐」：当前分类列表平滑回顶', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const HomeShell(), transport: fake);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final scrolled = verticalOffset(tester);
    expect(scrolled, greaterThan(100), reason: '前置：列表已滚离顶部');

    await tester.tap(find.text('推荐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midway = verticalOffset(tester);
    expect(midway, greaterThan(0), reason: '动画中途不应已经到顶（要平滑滚动）');
    expect(midway, lessThan(scrolled), reason: '动画中途应已开始向上滚');

    await tester.pumpAndSettle();
    expect(verticalOffset(tester), 0, reason: '再次点击推荐应滚回顶部');
  });

  testWidgets('首页-滚动后搜索框常驻顶部', (tester) async {
    final fake = FakePreviewTransport()..novelItemCount = 30;
    await pumpPreview(tester, const HomeShell(), transport: fake);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(
      find.byType(FeedSearchField),
      findsOneWidget,
      reason: '搜索框常驻顶部，滚动后也不收起',
    );
    expect(find.text('小说'), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('../goldens/home_scrolled.png'),
    );
  });

  /// 首页里切到「我的」：统一页头 + 小说/短剧两个 tab（真机是同一个
  /// Scaffold 里叠加悬浮胶囊，单独 pump MinePage 看不到胶囊）。
  testWidgets('首页-我的（统一页头与两个 tab）', (tester) async {
    await pumpPreview(tester, const HomeShell());
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    // 底栏「我的」+ 页头「我的」各一个。
    expect(find.text('我的'), findsNWidgets(2));
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('短剧'), findsOneWidget);
    expect(find.byKey(MinePage.novelTabKey), findsOneWidget);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('../goldens/home_mine.png'),
    );
  });
}
