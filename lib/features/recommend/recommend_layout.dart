import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页推荐流的布局：双列 / 三列瀑布流。
///
/// 默认双列：封面更大、更沉浸；三列一屏能多扫几本。两种布局共用同一套
/// 不定高卡片与瀑布流，切换只改列数（卡片宽度随之变化）。
enum RecommendLayout {
  two('双列', 2),
  three('三列', 3);

  const RecommendLayout(this.label, this.columns);

  /// 设置页选项文案。
  final String label;

  /// 瀑布流列数。
  final int columns;
}

/// 从持久化的枚举下标还原布局；缺失/越界一律回默认双列。
///
/// 抽成函数是因为启动预读（`main.dart`）和控制器异步恢复都要用同一套
/// 兜底规则，避免两边对"非法值"处理不一致。
RecommendLayout recommendLayoutFromIndex(int? index) {
  if (index == null || index < 0 || index >= RecommendLayout.values.length) {
    return RecommendLayout.two;
  }
  return RecommendLayout.values[index];
}

/// 当前推荐布局（设置页改、推荐页读）。
final recommendLayoutProvider =
    NotifierProvider<RecommendLayoutController, RecommendLayout>(
      RecommendLayoutController.new,
    );

/// 推荐布局持久化。
///
/// 与 [themeSeedProvider] / [themeModeProvider] 同一套模式：
/// - App 启动时 [main.dart] 先读盘，把值塞进 [RecommendLayoutController.initialLayout]，
///   首页首帧就是用户选的布局（否则会先按双列渲染再跳一次）；
/// - 没走启动预读时（测试/热重启），构造后异步补读磁盘，读到前先用默认双列。
///
/// 用户在读到磁盘前就切过布局时，不能被旧值覆盖。
class RecommendLayoutController extends Notifier<RecommendLayout> {
  RecommendLayoutController({this.initialLayout});

  /// 由启动流程预读好的布局；为 null 表示需要自己异步恢复。
  final RecommendLayout? initialLayout;

  static const layoutKey = 'home_recommend_layout_v1';

  bool _userChanged = false;

  @override
  RecommendLayout build() {
    final initial = initialLayout;
    if (initial != null) return initial;
    _restore();
    return RecommendLayout.two;
  }

  void setLayout(RecommendLayout layout) {
    if (layout == state) return;
    _userChanged = true;
    state = layout;
    _persist(layout);
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // await 期间 provider 可能已经销毁（页面被 pop / 容器 dispose）。
      if (!ref.mounted || _userChanged) return;
      final restored = recommendLayoutFromIndex(prefs.getInt(layoutKey));
      if (restored != state) state = restored;
    } catch (_) {
      // 读不到偏好就用默认双列，不影响启动。
    }
  }

  Future<void> _persist(RecommendLayout layout) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setInt(layoutKey, layout.index);
    } catch (_) {
      // 落盘失败只影响下次启动的默认布局，当前这次切换仍然生效。
    }
  }
}
