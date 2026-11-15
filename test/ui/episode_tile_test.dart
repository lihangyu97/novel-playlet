import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/video/widgets/episode_tile.dart';

/// 选集按钮的统一视觉：**无描边**、未选中一层淡底色、选中主色实心。
///
/// 详情页内嵌选集和播放页选集弹层共用这个组件，样式只在这里维护。
void main() {
  Future<void> pumpTiles(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Row(
            children: [
              EpisodeTile(index: 0, height: 34, radius: 8, onTap: () {}),
              EpisodeTile(
                index: 1,
                selected: true,
                height: 34,
                radius: 8,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('无描边：未选中淡底色、选中主色实心', (tester) async {
    await pumpTiles(tester);
    final scheme = Theme.of(tester.element(find.byType(EpisodeTile).first))
        .colorScheme;
    final buttons = tester.widgetList<TextButton>(find.byType(TextButton));

    final unselected = buttons.first;
    expect(
      unselected.style?.backgroundColor?.resolve(<WidgetState>{}),
      scheme.surfaceContainerHighest,
      reason: '未选中只给一层很淡的底色',
    );
    expect(
      unselected.style?.foregroundColor?.resolve(<WidgetState>{}),
      scheme.onSurface,
    );
    expect(
      (unselected.style?.shape?.resolve(
        <WidgetState>{},
      ) as RoundedRectangleBorder).side,
      BorderSide.none,
      reason: '不要描边',
    );

    final selected = buttons.last;
    expect(
      selected.style?.backgroundColor?.resolve(<WidgetState>{}),
      scheme.primary,
    );
    expect(
      selected.style?.foregroundColor?.resolve(<WidgetState>{}),
      scheme.onPrimary,
    );
  });

  testWidgets('只显示集数（1 基），点击回传自己的下标', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: EpisodeTile(index: 4, onTap: () => taps.add(4))),
        ),
      ),
    );
    expect(find.text('5'), findsOneWidget);
    expect(find.text('第 5 集'), findsNothing);
    await tester.tap(find.text('5'));
    expect(taps, [4]);
  });
}
