import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
