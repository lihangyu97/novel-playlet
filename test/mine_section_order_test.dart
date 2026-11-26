import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/mine/mine_section_order.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的」页区块顺序：默认值、脏值补齐、拖动落位、落盘恢复、云端回填。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('默认顺序：在看 → 收藏 → 历史', () {
    expect(defaultMineSectionOrder, [
      MineSection.pins,
      MineSection.collection,
      MineSection.history,
    ]);
    expect(mineSectionOrderNames(defaultMineSectionOrder), [
      'pins',
      'collection',
      'history',
    ]);
    expect(
      sameMineSectionOrder(defaultMineSectionOrder, [
        MineSection.pins,
        MineSection.collection,
        MineSection.history,
      ]),
      isTrue,
    );
    expect(
      sameMineSectionOrder(defaultMineSectionOrder, [
        MineSection.collection,
        MineSection.pins,
        MineSection.history,
      ]),
      isFalse,
    );
  });

  test('解析：去重、丢弃未知、缺项按默认顺序补齐', () {
    expect(mineSectionOrderFromNames(null), defaultMineSectionOrder);
    expect(
      mineSectionOrderFromNames(const <Object?>[]),
      defaultMineSectionOrder,
    );
    expect(
      mineSectionOrderFromNames(const ['history', 'pins', 'history']),
      [MineSection.history, MineSection.pins, MineSection.collection],
      reason: '重复项只留第一次出现的那个',
    );
    expect(
      mineSectionOrderFromNames(const ['bogus', 42, 'collection']),
      [MineSection.collection, MineSection.pins, MineSection.history],
      reason: '不认识的 name 丢掉，缺的按默认顺序补到最后',
    );
  });

  test('拖动落位：上移 / 下移 / 原地 / 越界', () {
    const order = defaultMineSectionOrder;
    expect(reorderMineSections(order, 2, 0), [
      MineSection.history,
      MineSection.pins,
      MineSection.collection,
    ]);
    expect(reorderMineSections(order, 0, 2), [
      MineSection.collection,
      MineSection.history,
      MineSection.pins,
    ]);
    expect(reorderMineSections(order, 1, 1), order, reason: '原地不动');
    expect(reorderMineSections(order, 5, 0), order, reason: '越界原样返回');
    expect(
      reorderMineSections(order, 0, 9),
      [MineSection.collection, MineSection.history, MineSection.pins],
      reason: '目标下标夹到末尾',
    );
  });

  test('拖完落盘，新容器先从默认顺序起、随后恢复', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(mineSectionOrderProvider.notifier).setOrder(const [
      MineSection.history,
      MineSection.collection,
      MineSection.pins,
    ]);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(MineSectionOrderController.orderKey), [
      'history',
      'collection',
      'pins',
    ]);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(
      restored.read(mineSectionOrderProvider),
      defaultMineSectionOrder,
      reason: '异步读盘前先用默认顺序',
    );
    await pumpEventQueue();
    expect(restored.read(mineSectionOrderProvider), [
      MineSection.history,
      MineSection.collection,
      MineSection.pins,
    ]);
  });

  test('顺序没变不写盘，避免一次无意义的上传', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(mineSectionOrderProvider.notifier)
        .setOrder(defaultMineSectionOrder);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(MineSectionOrderController.orderKey), isNull);
  });

  test('云端顺序覆盖本地，且不被随后读到的磁盘旧值盖回去', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MineSectionOrderController.orderKey: <String>[
        'pins',
        'collection',
        'history',
      ],
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(mineSectionOrderProvider.notifier).applyRemote(const [
      MineSection.collection,
      MineSection.history,
      MineSection.pins,
    ]);
    await pumpEventQueue();

    expect(container.read(mineSectionOrderProvider), [
      MineSection.collection,
      MineSection.history,
      MineSection.pins,
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(MineSectionOrderController.orderKey), [
      'collection',
      'history',
      'pins',
    ]);
  });

  test('恢复默认', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(mineSectionOrderProvider.notifier).setOrder(const [
      MineSection.history,
      MineSection.pins,
      MineSection.collection,
    ]);
    await pumpEventQueue();

    container.read(mineSectionOrderProvider.notifier).reset();
    await pumpEventQueue();
    expect(container.read(mineSectionOrderProvider), defaultMineSectionOrder);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(MineSectionOrderController.orderKey), [
      'pins',
      'collection',
      'history',
    ]);
  });
}
