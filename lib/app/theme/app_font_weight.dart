import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局字重可选档位。只开放整百，避免主题里出现 350/450 这类中间值。
const List<int> appFontWeightSteps = [300, 400, 500, 600, 700];

/// 把持久化/外部传入的数值收敛到最近的合法档位；非法值回默认 400。
FontWeight appFontWeightFromValue(int? value) {
  final target = value ?? FontWeight.w400.value;
  final stepped = appFontWeightSteps.reduce(
    (best, candidate) =>
        (candidate - target).abs() < (best - target).abs() ? candidate : best,
  );
  return FontWeight.values.firstWhere(
    (weight) => weight.value == stepped,
    orElse: () => FontWeight.w400,
  );
}

/// 用户选择的全局字重。
///
/// 这是「设置里的值」；是否真正生效由 [appEffectiveFontWeightProvider]
/// 决定：iOS 固定 400（不暴露该设置，也不受持久化值影响）。
final appFontWeightProvider =
    NotifierProvider<AppFontWeightController, FontWeight>(
      AppFontWeightController.new,
    );

/// 当前平台真正生效的全局字重。
///
/// 放在 provider 里而不是各处判断 `defaultTargetPlatform`，保证主题、设置页
/// 和阅读器用的是同一个值；测试也可以覆盖平台后直接读它。
final appEffectiveFontWeightProvider = Provider<FontWeight>((ref) {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return FontWeight.w400;
  }
  return ref.watch(appFontWeightProvider);
});

class AppFontWeightController extends Notifier<FontWeight> {
  AppFontWeightController({this.initialFontWeight});

  /// 由启动流程预读好的值；null 表示需要自己异步恢复。
  final FontWeight? initialFontWeight;

  static const fontWeightKey = 'app_font_weight_v1';

  bool _userChanged = false;

  @override
  FontWeight build() {
    final initial = initialFontWeight;
    if (initial != null) return initial;
    _restore();
    return FontWeight.w400;
  }

  void setFontWeight(FontWeight weight) {
    final next = appFontWeightFromValue(weight.value);
    if (next == state) return;
    _userChanged = true;
    state = next;
    _persist(next);
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _userChanged) return;
      final restored = appFontWeightFromValue(prefs.getInt(fontWeightKey));
      if (restored != state) state = restored;
    } catch (_) {
      // 读不到偏好就用默认字重，不影响启动。
    }
  }

  Future<void> _persist(FontWeight weight) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setInt(fontWeightKey, weight.value);
    } catch (_) {
      // 落盘失败只影响下次启动的默认值，当前这次切换仍然生效。
    }
  }
}
