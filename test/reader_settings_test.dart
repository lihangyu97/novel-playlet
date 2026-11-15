import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/app/theme/app_font_weight.dart';
import 'package:novel_playlet/features/reader/reader_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读设置里「对话高亮」开关的默认值与落盘/恢复。
void main() {
  test('对话高亮默认开，关闭后落盘并在新容器恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(readerSettingsProvider).showDialogueHighlight,
      isTrue,
    );

    container
        .read(readerSettingsProvider.notifier)
        .setShowDialogueHighlight(false);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('reader_show_dialogue_highlight_v1'), isFalse);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      restored.read(readerSettingsProvider).showDialogueHighlight,
      isFalse,
      reason: '下次启动要沿用关闭状态',
    );
  });

  test('字重默认 400，可调到 700 并落盘恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(readerSettingsProvider).fontWeight, FontWeight.w400);

    container.read(readerSettingsProvider.notifier).setFontWeight(700);
    await pumpEventQueue();
    expect(container.read(readerSettingsProvider).fontWeight, FontWeight.w700);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('reader_font_weight_v1'), 700);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      restored.read(readerSettingsProvider).fontWeight,
      FontWeight.w700,
      reason: '下次启动要沿用上次字重',
    );
  });

  test('字重只落在 300–800 的整百档', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settings = container.read(readerSettingsProvider.notifier);
    settings.setFontWeight(999);
    expect(container.read(readerSettingsProvider).fontWeight, FontWeight.w800);
    settings.setFontWeight(100);
    expect(container.read(readerSettingsProvider).fontWeight, FontWeight.w300);
  });

  test('阅读器默认跟随全局字重，单独调字重后覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        appEffectiveFontWeightProvider.overrideWithValue(FontWeight.w600),
      ],
    );
    addTearDown(container.dispose);
    expect(
      container.read(readerSettingsProvider).followGlobalFontWeight,
      isTrue,
    );
    expect(
      container.read(readerEffectiveFontWeightProvider),
      FontWeight.w600,
      reason: '默认跟随全局时应使用全局值',
    );

    container.read(readerSettingsProvider.notifier).setFontWeight(700);
    await pumpEventQueue();
    expect(
      container.read(readerSettingsProvider).followGlobalFontWeight,
      isFalse,
    );
    expect(container.read(readerEffectiveFontWeightProvider), FontWeight.w700);

    final restored = ProviderContainer(
      overrides: [
        appEffectiveFontWeightProvider.overrideWithValue(FontWeight.w600),
      ],
    );
    addTearDown(restored.dispose);
    await restored.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      restored.read(readerSettingsProvider).followGlobalFontWeight,
      isFalse,
      reason: '用户手动调过阅读器字重后，下次启动不能又被全局覆盖',
    );
    expect(restored.read(readerEffectiveFontWeightProvider), FontWeight.w700);
  });

  test('老版本已存阅读器字重的用户迁移为不跟随全局', () async {
    SharedPreferences.setMockInitialValues({'reader_font_weight_v1': 700});
    final container = ProviderContainer(
      overrides: [
        appEffectiveFontWeightProvider.overrideWithValue(FontWeight.w600),
      ],
    );
    addTearDown(container.dispose);
    await container.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      container.read(readerSettingsProvider).followGlobalFontWeight,
      isFalse,
    );
    expect(container.read(readerEffectiveFontWeightProvider), FontWeight.w700);
  });

  test('对话高亮颜色可改、落盘并在新容器恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(readerSettingsProvider).dialogueHighlightColor,
      ReaderSettings.defaultDialogueHighlightColor,
    );

    const picked = Color(0xFF66BB6A);
    container
        .read(readerSettingsProvider.notifier)
        .setDialogueHighlightColor(picked);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('reader_dialogue_highlight_color_v1'),
      picked.toARGB32(),
    );

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      restored.read(readerSettingsProvider).dialogueHighlightColor,
      picked,
    );
  });

  test('对话高亮样式可改、落盘并在新容器恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(readerSettingsProvider).dialogueHighlightStyle,
      DialogueHighlightStyle.marker,
      reason: '默认还是荧光笔（老用户升级后观感不变）',
    );

    container
        .read(readerSettingsProvider.notifier)
        .setDialogueHighlightStyle(DialogueHighlightStyle.wavy);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('reader_dialogue_highlight_style_v1'), 'wavy');

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      restored.read(readerSettingsProvider).dialogueHighlightStyle,
      DialogueHighlightStyle.wavy,
    );
  });

  test('落盘的样式名不认识时回退荧光笔，不抛异常', () async {
    SharedPreferences.setMockInitialValues({
      'reader_dialogue_highlight_style_v1': 'some_future_style',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      container.read(readerSettingsProvider).dialogueHighlightStyle,
      DialogueHighlightStyle.marker,
    );
  });

  test('落盘的关闭值优先于默认值', () async {
    SharedPreferences.setMockInitialValues({
      'reader_show_dialogue_highlight_v1': false,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(readerSettingsProvider.notifier).restoreFuture;
    expect(
      container.read(readerSettingsProvider).showDialogueHighlight,
      isFalse,
    );
  });
}
