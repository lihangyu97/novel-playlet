import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史最多保留多少条。
const int searchHistoryLimit = 10;

/// 搜索历史落盘 key（StringList）。
const String searchHistoryKey = 'search_history_v1';

/// 搜索历史：最近搜过的关键词，最新的在最前面。
///
/// 全局 provider（不 autoDispose）：关闭搜索页、切 tab 再回来都还在；
/// 首次读取异步恢复，恢复期间先给空列表，不阻塞页面。
final searchHistoryProvider =
    NotifierProvider<SearchHistoryController, List<String>>(
      SearchHistoryController.new,
    );

class SearchHistoryController extends Notifier<List<String>> {
  bool _userChanged = false;

  @override
  List<String> build() {
    _restore();
    return const <String>[];
  }

  /// 记一条：去重（命中已有项就提到最前）、空白忽略、最多 [searchHistoryLimit] 条。
  void add(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    final next = <String>[
      query,
      ...state.where((item) => item != query),
    ].take(searchHistoryLimit).toList(growable: false);
    _userChanged = true;
    state = List<String>.unmodifiable(next);
    _persist();
  }

  void clear() {
    if (state.isEmpty) return;
    _userChanged = true;
    state = const <String>[];
    _persist();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // await 期间用户可能已经搜了一次 / 清空过：不要用旧值覆盖新状态。
      if (!ref.mounted || _userChanged) return;
      final stored = prefs.getStringList(searchHistoryKey) ?? const <String>[];
      state = List<String>.unmodifiable(
        stored.take(searchHistoryLimit).toList(growable: false),
      );
    } catch (_) {
      // 读不到历史就按空历史显示，不影响搜索本身。
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setStringList(searchHistoryKey, state);
    } catch (_) {
      // 落盘失败只影响下次启动，当前这次搜索/清空仍然生效。
    }
  }
}
