import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的」页的三个区块。
///
/// 顺序用户可调（设置 → 外观 →「我的页模块」）。枚举 `name` 是持久化与云端
/// 同步的唯一标识：prefs 和 `settings.json` 都存 name、不存下标，以后插入
/// 新区块时老数据不会错位。
enum MineSection {
  pins('在看', Icons.push_pin_outlined),
  collection('收藏', Icons.star_border_rounded),
  history('历史', Icons.history_rounded);

  const MineSection(this.label, this.icon);

  /// 区块标题；设置页拖动行也用它。
  final String label;

  /// 设置页拖动行的行首图标（我的页区块头不画图标）。
  final IconData icon;
}

/// 默认顺序：与「顺序可调」之前一致，老用户升级后观感不变。
const defaultMineSectionOrder = <MineSection>[
  MineSection.pins,
  MineSection.collection,
  MineSection.history,
];

/// 把持久化 / 云端的 name 列表还原成一个完整排列。
///
/// 去重、丢弃不认识的名字、缺的按默认顺序补到末尾：**永远返回三个区块各一次**。
/// 脏数据不会让某个区块消失，也不会让页面出现两个同名区块；以后加第四个区块
/// 时，老数据缺的那一项自动补到最后。
List<MineSection> mineSectionOrderFromNames(Iterable<Object?>? names) {
  final order = <MineSection>[];
  for (final name in names ?? const <Object?>[]) {
    if (name is! String) continue;
    for (final section in MineSection.values) {
      if (section.name == name) {
        if (!order.contains(section)) order.add(section);
        break;
      }
    }
  }
  for (final section in MineSection.values) {
    if (!order.contains(section)) order.add(section);
  }
  return order;
}

/// 顺序的持久化形态：枚举 name 列表。
List<String> mineSectionOrderNames(List<MineSection> order) => [
  for (final section in order) section.name,
];

/// 两组顺序是否完全一致。
bool sameMineSectionOrder(List<MineSection> a, List<MineSection> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 把 [oldIndex] 那一条移到 [newIndex]（移动后的目标下标）后的新顺序。
///
/// `ReorderableListView.onReorderItem` 给的 `newIndex` 已经按「先移除再插入」
/// 修正过，这里不用再减 1；读屏的「上移 / 下移」也复用这个函数。下标越界一律
/// 原样返回，不抛异常。
List<MineSection> reorderMineSections(
  List<MineSection> order,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex < 0 || oldIndex >= order.length) {
    return List<MineSection>.of(order);
  }
  var target = newIndex;
  if (target < 0) target = 0;
  if (target > order.length - 1) target = order.length - 1;
  final next = List<MineSection>.of(order);
  if (oldIndex == target) return next;
  next.insert(target, next.removeAt(oldIndex));
  return next;
}

/// 当前「我的」页区块顺序（设置页改、我的页读）。
final mineSectionOrderProvider =
    NotifierProvider<MineSectionOrderController, List<MineSection>>(
      MineSectionOrderController.new,
    );

/// 区块顺序持久化。
///
/// 与推荐流布局（`recommend_layout.dart`）同一套模式：
/// - 默认顺序先上屏，随后异步补读磁盘（我的页是第二个 tab，读盘在首帧前后的
///   微任务里就完成，看不到跳变）；
/// - 用户在读到磁盘前就拖过顺序时，不能被旧值覆盖（`_userChanged`）；
/// - 云端回填走 [applyRemote]，绕过「用户改过就跳过」的恢复守卫。
class MineSectionOrderController extends Notifier<List<MineSection>> {
  MineSectionOrderController({this.initialOrder});

  /// 测试 / 以后接启动预读时直接给定顺序；null = 自己异步恢复。
  final List<MineSection>? initialOrder;

  static const orderKey = 'mine_section_order_v1';

  bool _userChanged = false;
  Future<void>? _restoreFuture;

  /// 本地恢复完成（或无需恢复）的 Future。
  Future<void> get restoreFuture {
    if (initialOrder != null) return Future<void>.value();
    return _restoreFuture ??= _restore();
  }

  @override
  List<MineSection> build() {
    final initial = initialOrder;
    if (initial != null) return List<MineSection>.unmodifiable(initial);
    _restoreFuture = _restore();
    return defaultMineSectionOrder;
  }

  /// 应用云端顺序：直接改状态并落盘。
  Future<void> applyRemote(List<MineSection> order) async {
    _userChanged = true;
    if (!sameMineSectionOrder(order, state)) {
      state = List<MineSection>.unmodifiable(order);
    }
    await _persist(order);
  }

  /// 拖拽落位。
  ///
  /// 顺序没变时不写盘：避免一次无意义的设置上传和同步记录。
  void setOrder(List<MineSection> order) {
    if (sameMineSectionOrder(order, state)) return;
    _userChanged = true;
    state = List<MineSection>.unmodifiable(order);
    _persist(order);
  }

  /// 恢复默认顺序（在看 → 收藏 → 历史）。
  void reset() => setOrder(defaultMineSectionOrder);

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // await 期间 provider 可能已经销毁，或用户已经拖过顺序。
      if (!ref.mounted || _userChanged) return;
      final restored = mineSectionOrderFromNames(prefs.getStringList(orderKey));
      if (!sameMineSectionOrder(restored, state)) {
        state = List<MineSection>.unmodifiable(restored);
      }
    } catch (_) {
      // 读不到偏好就用默认顺序，不影响启动。
    }
  }

  Future<void> _persist(List<MineSection> order) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setStringList(orderKey, mineSectionOrderNames(order));
    } catch (_) {
      // 落盘失败只影响下次启动的顺序，当前这次调整仍然生效。
    }
  }
}
