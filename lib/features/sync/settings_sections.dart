import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_font_weight.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/theme_settings.dart';
import '../mine/mine_section_order.dart';
import '../reader/reader_settings.dart';
import '../recommend/recommend_layout.dart';

/// 一组可同步设置。新增设置时优先加在已有 section 里，只改 capture /
/// applyRemote 两个 map；新增一整组设置才加一个 section。
///
/// 同步层只认识这个接口，不认识具体 provider，避免每加一项就在快照、
/// 校验、脏标记、日志里各写一遍。
abstract interface class SettingsSection {
  /// `settings.json` 里的 key，同时也是日志/状态里的分组名。
  String get id;

  /// 当前本机值，必须是 JSON 可编码的原始类型。
  Object? capture();

  /// 应用云端值；非法/缺失字段由 section 自己 clamp 或回落默认。
  Future<void> applyRemote(Object? data);
}

final settingsSectionsProvider = Provider<List<SettingsSection>>((ref) {
  return [
    ThemeSettingsSection(ref),
    FontWeightSettingsSection(ref),
    FeedSettingsSection(ref),
    MineSettingsSection(ref),
    ReaderSettingsSection(ref),
  ];
});

/// 主题色 / 深浅色 / 上次自定义色。
class ThemeSettingsSection implements SettingsSection {
  const ThemeSettingsSection(this.ref);

  final Ref ref;

  @override
  String get id => 'theme';

  @override
  Object? capture() => {
    'seed': ref.read(themeSeedProvider).toARGB32(),
    'mode': _themeModeName(ref.read(themeModeProvider)),
    'customSeed': ref.read(customThemeSeedProvider).toARGB32(),
  };

  @override
  Future<void> applyRemote(Object? data) async {
    final map = _map(data);
    await ref
        .read(themeSeedProvider.notifier)
        .applyRemote(_color(map['seed'], appSeedColor));
    await ref
        .read(customThemeSeedProvider.notifier)
        .applyRemote(
          _color(map['customSeed'], CustomThemeSeedController.fallback),
        );
    await ref
        .read(themeModeProvider.notifier)
        .applyRemote(_themeMode(map['mode']));
  }
}

/// 全局字重（仅 Android 真正生效，iOS 拉到也无害）。
class FontWeightSettingsSection implements SettingsSection {
  const FontWeightSettingsSection(this.ref);

  final Ref ref;

  @override
  String get id => 'fontWeight';

  @override
  Object? capture() => ref.read(appFontWeightProvider).value;

  @override
  Future<void> applyRemote(Object? data) async {
    await ref
        .read(appFontWeightProvider.notifier)
        .applyRemote(_fontWeight(appFontWeightSteps, data, FontWeight.w400));
  }
}

/// 推荐流布局（双列 / 三列）。
class FeedSettingsSection implements SettingsSection {
  const FeedSettingsSection(this.ref);

  final Ref ref;

  @override
  String get id => 'feed';

  @override
  Object? capture() => {'layout': ref.read(recommendLayoutProvider).name};

  @override
  Future<void> applyRemote(Object? data) async {
    final layout = _map(data)['layout'] == RecommendLayout.three.name
        ? RecommendLayout.three
        : RecommendLayout.two;
    await ref.read(recommendLayoutProvider.notifier).applyRemote(layout);
  }
}

/// 「我的」页区块顺序（在看 / 收藏 / 历史）。
///
/// 只存 name 列表：顺序是观感偏好，跨设备一致才有意义；脏值由
/// [mineSectionOrderFromNames] 补齐成完整排列，不会让某个区块消失。
class MineSettingsSection implements SettingsSection {
  const MineSettingsSection(this.ref);

  final Ref ref;

  @override
  String get id => 'mine';

  @override
  Object? capture() => {
    'sections': mineSectionOrderNames(ref.read(mineSectionOrderProvider)),
  };

  @override
  Future<void> applyRemote(Object? data) async {
    final raw = _map(data)['sections'];
    final names = raw is List ? raw : const <Object?>[];
    await ref
        .read(mineSectionOrderProvider.notifier)
        .applyRemote(mineSectionOrderFromNames(names));
  }
}

/// 阅读排版 10 项。
class ReaderSettingsSection implements SettingsSection {
  const ReaderSettingsSection(this.ref);

  final Ref ref;

  @override
  String get id => 'reader';

  @override
  Object? capture() {
    final settings = ref.read(readerSettingsProvider);
    return {
      'fontSize': settings.fontSize,
      'lineHeight': settings.lineHeight,
      'fontWeight': settings.fontWeight.value,
      'followGlobalFontWeight': settings.followGlobalFontWeight,
      'paper': settings.paper.name,
      'dayPaper': settings.dayPaper.name,
      'showBubbles': settings.showBubbles,
      'showDialogueHighlight': settings.showDialogueHighlight,
      'dialogueHighlightColor': settings.dialogueHighlightColor.toARGB32(),
      'dialogueHighlightStyle': settings.dialogueHighlightStyle.name,
    };
  }

  @override
  Future<void> applyRemote(Object? data) async {
    final map = _map(data);
    const fallback = ReaderSettings();
    final paper = _paper(map['paper'], fallback.paper);
    var dayPaper = _paper(map['dayPaper'], fallback.dayPaper);
    if (dayPaper == ReaderPaper.night) dayPaper = fallback.dayPaper;

    await ref
        .read(readerSettingsProvider.notifier)
        .applyRemote(
          ReaderSettings(
            fontSize: _double(map['fontSize'], fallback.fontSize).clamp(
              ReaderSettingsController.minFontSize,
              ReaderSettingsController.maxFontSize,
            ),
            lineHeight: _double(map['lineHeight'], fallback.lineHeight).clamp(
              ReaderSettingsController.minLineHeight,
              ReaderSettingsController.maxLineHeight,
            ),
            fontWeight: _fontWeight(
              ReaderSettingsController.fontWeightSteps,
              map['fontWeight'],
              fallback.fontWeight,
            ),
            followGlobalFontWeight: _bool(
              map['followGlobalFontWeight'],
              fallback.followGlobalFontWeight,
            ),
            paper: paper,
            dayPaper: dayPaper,
            showBubbles: _bool(map['showBubbles'], fallback.showBubbles),
            showDialogueHighlight: _bool(
              map['showDialogueHighlight'],
              fallback.showDialogueHighlight,
            ),
            dialogueHighlightColor: _color(
              map['dialogueHighlightColor'],
              fallback.dialogueHighlightColor,
            ),
            dialogueHighlightStyle: _style(
              map['dialogueHighlightStyle'],
              fallback.dialogueHighlightStyle,
            ),
          ),
        );
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};

Color _color(Object? value, Color fallback) {
  if (value is int && value >= 0 && value <= 0xFFFFFFFF) return Color(value);
  return fallback;
}

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

double _double(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  return fallback;
}

FontWeight _fontWeight(List<int> steps, Object? value, FontWeight fallback) {
  final target = value is num ? value.round() : fallback.value;
  final stepped = steps.reduce(
    (best, candidate) =>
        (candidate - target).abs() < (best - target).abs() ? candidate : best,
  );
  return FontWeight.values.firstWhere(
    (weight) => weight.value == stepped,
    orElse: () => fallback,
  );
}

String _themeModeName(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

ThemeMode _themeMode(Object? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

ReaderPaper _paper(Object? value, ReaderPaper fallback) => ReaderPaper.values
    .firstWhere((paper) => paper.name == value, orElse: () => fallback);

DialogueHighlightStyle _style(Object? value, DialogueHighlightStyle fallback) =>
    DialogueHighlightStyle.values.firstWhere(
      (style) => style.name == value,
      orElse: () => fallback,
    );
