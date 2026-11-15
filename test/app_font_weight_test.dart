import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_font_weight.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('全局字重平移 textTheme 和组件强调字重', () {
    final base = AppTheme.light();
    final heavy = AppTheme.light(appSeedColor, FontWeight.w700);

    expect(base.extension<AppFontWeightScale>()?.delta, 0);
    expect(heavy.extension<AppFontWeightScale>()?.delta, 3);
    expect(base.textTheme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(heavy.textTheme.bodyMedium?.fontWeight, FontWeight.w700);
    expect(
      heavy.textTheme.titleSmall?.fontWeight?.value,
      (base.textTheme.titleSmall!.fontWeight!.value + 300).clamp(100, 900),
    );
    expect(heavy.appBarTheme.titleTextStyle?.fontWeight, FontWeight.w900);
    expect(
      heavy.navigationBarTheme.labelTextStyle?.resolve({
        WidgetState.selected,
      })?.fontWeight,
      FontWeight.w900,
    );
  });

  testWidgets('页面里写死的强调字重也跟随主题偏移', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(appSeedColor, FontWeight.w600),
        home: Builder(
          builder: (context) => Text(
            'x',
            style: TextStyle(fontWeight: context.appWeight(FontWeight.w500)),
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.text('x'));
    expect(text.style?.fontWeight, FontWeight.w700);
  });

  test('全局字重只接受 300–700 的整百档', () {
    expect(appFontWeightFromValue(999), FontWeight.w700);
    expect(appFontWeightFromValue(100), FontWeight.w300);
    expect(appFontWeightFromValue(null), FontWeight.w400);
  });

  test('全局字重落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(appFontWeightProvider.notifier)
        .setFontWeight(FontWeight.w700);
    await pumpEventQueue();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppFontWeightController.fontWeightKey), 700);
  });

  test('iOS 不使用全局字重，Android 使用', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final ios = ProviderContainer(
      overrides: [
        appFontWeightProvider.overrideWith(
          () => AppFontWeightController(initialFontWeight: FontWeight.w700),
        ),
      ],
    );
    addTearDown(ios.dispose);
    expect(ios.read(appEffectiveFontWeightProvider), FontWeight.w400);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final android = ProviderContainer(
      overrides: [
        appFontWeightProvider.overrideWith(
          () => AppFontWeightController(initialFontWeight: FontWeight.w700),
        ),
      ],
    );
    addTearDown(android.dispose);
    expect(android.read(appEffectiveFontWeightProvider), FontWeight.w700);
  });
}
