import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// 主题色预设。只留三个日常色，其余交给「自定义」取色。
@immutable
class ThemeColorOption {
  const ThemeColorOption(this.name, this.color);

  final String name;
  final Color color;
}

const themeColorOptions = <ThemeColorOption>[
  ThemeColorOption('天蓝', appSeedColor),
  ThemeColorOption('草绿', Color(0xFF66BB6A)),
  ThemeColorOption('绯红', Color(0xFFEF5350)),
];

/// 主题色的展示名：命中预设用预设名，否则叫「自定义」。
String themeColorName(Color color) {
  for (final option in themeColorOptions) {
    if (option.color == color) return option.name;
  }
  return '自定义';
}

/// 当前主题色是不是预设色之一（否则算自定义）。
bool isPresetColor(Color color) =>
    themeColorOptions.any((option) => option.color == color);

/// 当前主题 seed。改它 = 整站换色（MaterialApp 在 app.dart 里 watch）。
final themeSeedProvider = NotifierProvider<ThemeSeedController, Color>(
  ThemeSeedController.new,
);

/// 主题色持久化。
///
/// 两种入口：
/// - App 启动时 [main.dart] 先读盘，把值塞进 [ThemeSeedController.initialSeed]，
///   首帧就是用户选的颜色（否则会先闪一下天蓝再切过去）；
/// - 没走启动预读时（测试/热重启），构造后异步补读磁盘，读到前先用默认色。
///
/// 用户在读到磁盘前就点过颜色时，不能被旧值覆盖。
class ThemeSeedController extends Notifier<Color> {
  ThemeSeedController({this.initialSeed});

  /// 由启动流程预读好的主题色；为 null 表示需要自己异步恢复。
  final Color? initialSeed;

  static const seedKey = 'app_seed_color_v1';

  bool _userChanged = false;

  @override
  Color build() {
    final initial = initialSeed;
    if (initial != null) return initial;
    _restore();
    return appSeedColor;
  }

  void setSeed(Color color) {
    if (color == state) return;
    _userChanged = true;
    state = color;
    _persist(color);
  }

  /// 回到默认天蓝。
  void reset() => setSeed(appSeedColor);

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // await 期间 provider 可能已经销毁（页面被 pop / 容器 dispose）。
      if (!ref.mounted || _userChanged) return;
      final argb = prefs.getInt(seedKey);
      if (argb == null) return;
      final restored = Color(argb);
      if (restored != state) state = restored;
    } catch (_) {
      // 读不到偏好就用默认色，不影响启动。
    }
  }

  Future<void> _persist(Color color) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setInt(seedKey, color.toARGB32());
    } catch (_) {
      // 落盘失败只影响下次启动的默认色，当前这次换色仍然生效。
    }
  }
}

/// 全局深浅色模式。
///
/// 默认 [ThemeMode.system]（跟随系统）；设置页可以显式选浅色/深色。
/// 与 [themeSeedProvider] 一样，启动时由 `main.dart` 预读，避免首帧先按
/// 浅色渲染再闪一下。
final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// 深浅色模式持久化。
///
/// 存 [ThemeMode.index]：0 = system、1 = light、2 = dark（Flutter 枚举顺序）。
class ThemeModeController extends Notifier<ThemeMode> {
  ThemeModeController({this.initialMode});

  /// 由启动流程预读好的模式；为 null 表示需要自己异步恢复。
  final ThemeMode? initialMode;

  static const modeKey = 'app_theme_mode_v1';

  bool _userChanged = false;

  @override
  ThemeMode build() {
    final initial = initialMode;
    if (initial != null) return initial;
    _restore();
    return ThemeMode.system;
  }

  void setMode(ThemeMode mode) {
    if (mode == state) return;
    _userChanged = true;
    state = mode;
    _persist(mode);
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _userChanged) return;
      final index = prefs.getInt(modeKey);
      if (index == null || index < 0 || index >= ThemeMode.values.length) {
        return;
      }
      final restored = ThemeMode.values[index];
      if (restored != state) state = restored;
    } catch (_) {
      // 读不到偏好就跟随系统，不影响启动。
    }
  }

  Future<void> _persist(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setInt(modeKey, mode.index);
    } catch (_) {
      // 落盘失败只影响下次启动，当前这次切换仍然生效。
    }
  }
}
