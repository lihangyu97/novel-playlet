import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/recommend/recommend_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页推荐布局偏好：默认双列、切换落盘、新的容器从偏好恢复、非法值回落。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认双列', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(recommendLayoutProvider), RecommendLayout.two);
    expect(RecommendLayout.two.columns, 2);
    expect(RecommendLayout.three.columns, 3);
    expect(RecommendLayout.two.label, '双列');
    expect(RecommendLayout.three.label, '三列');
  });

  test('切到三列会落盘，新容器能从偏好恢复', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(recommendLayoutProvider.notifier)
        .setLayout(RecommendLayout.three);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(RecommendLayoutController.layoutKey),
      RecommendLayout.three.index,
    );

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(
      restored.read(recommendLayoutProvider),
      RecommendLayout.two,
      reason: '异步读盘前先用默认双列',
    );
    await pumpEventQueue();
    expect(restored.read(recommendLayoutProvider), RecommendLayout.three);
  });

  test('启动预读的布局首帧就生效，且不再被磁盘值覆盖', () async {
    SharedPreferences.setMockInitialValues({
      RecommendLayoutController.layoutKey: RecommendLayout.three.index,
    });
    final container = ProviderContainer(
      overrides: [
        recommendLayoutProvider.overrideWith(
          () => RecommendLayoutController(initialLayout: RecommendLayout.two),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(recommendLayoutProvider), RecommendLayout.two);
    await pumpEventQueue();
    expect(
      container.read(recommendLayoutProvider),
      RecommendLayout.two,
      reason: '预读后不应再被磁盘值覆盖',
    );
  });

  test('磁盘值越界回落默认双列', () async {
    SharedPreferences.setMockInitialValues({
      RecommendLayoutController.layoutKey: 9,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 先读一次触发异步恢复。
    container.read(recommendLayoutProvider);
    await pumpEventQueue();
    expect(container.read(recommendLayoutProvider), RecommendLayout.two);
  });

  test('recommendLayoutFromIndex 处理缺失与越界', () {
    expect(recommendLayoutFromIndex(null), RecommendLayout.two);
    expect(recommendLayoutFromIndex(-1), RecommendLayout.two);
    expect(recommendLayoutFromIndex(2), RecommendLayout.two);
    expect(recommendLayoutFromIndex(0), RecommendLayout.two);
    expect(recommendLayoutFromIndex(1), RecommendLayout.three);
  });

  test('用户切换到同一布局时不重复落盘', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 默认就是双列，再 set 一次不应产生写入。
    container
        .read(recommendLayoutProvider.notifier)
        .setLayout(RecommendLayout.two);
    await pumpEventQueue();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(RecommendLayoutController.layoutKey), isNull);
  });
}
