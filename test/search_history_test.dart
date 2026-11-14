import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/search/search_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史的状态规则：去重置顶、上限、清空。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('新词置顶、重复词提到最前、最多保留 10 条', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final history = container.read(searchHistoryProvider.notifier);

    for (var i = 1; i <= 12; i++) {
      history.add('词$i');
    }
    expect(
      container.read(searchHistoryProvider),
      hasLength(searchHistoryLimit),
    );
    expect(container.read(searchHistoryProvider).first, '词12');
    expect(container.read(searchHistoryProvider), isNot(contains('词1')));

    history.add('词5');
    expect(container.read(searchHistoryProvider).first, '词5');
    expect(
      container.read(searchHistoryProvider).where((item) => item == '词5'),
      hasLength(1),
      reason: '重复关键词不能出现两次',
    );

    history.add('   ');
    expect(container.read(searchHistoryProvider).first, '词5');

    history.clear();
    expect(container.read(searchHistoryProvider), isEmpty);
  });
}
