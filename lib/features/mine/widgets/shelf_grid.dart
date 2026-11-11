import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// 我的页的卡片网格：白底不定高卡片 + 瀑布流 + 空态，长按交给父级弹管理菜单。
///
/// 与推荐页同一套卡片视觉（`MediaCard.surface` + 内容域原生封面比例 +
/// 标题自然高度），卡片高度由内容决定，所以用瀑布流而不是固定行高的
/// `GridView`。个人数据量级不大，`MasonryGridView` 的 shrinkWrap 形态直接
/// 嵌在 [MineTabBody] 的 Column 里，不另起滚动物理。
///
/// 小说 / 短剧两个 tab 共用这层骨架：列数、列宽、间距、空态高度都按同一套
/// 规则，两侧只注入卡片类型、元信息与空态文案。
class ShelfGrid<T> extends StatelessWidget {
  const ShelfGrid({
    super.key,
    required this.items,
    required this.crossAxisCount,
    required this.spacing,
    required this.cardBuilder,
    required this.emptyState,
    required this.onLongPress,
    this.heroTagOf,
  });

  final List<T> items;
  final int crossAxisCount;
  final double spacing;

  /// 卡片构建：拿到条目与 [heroTagOf] 算出的 Hero tag。
  final Widget Function(T item, String? heroTag) cardBuilder;
  final ValueChanged<T> onLongPress;

  /// 空态内容（图标 + 文案）；外层留白与高度由本组件统一。
  final Widget emptyState;

  /// 封面 Hero tag；null = 不参与飞入动画。
  final String Function(T item)? heroTagOf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(height: 200, child: emptyState),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: MasonryGridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: spacing,
        mainAxisSpacing: 8,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          // 卡片只接了 onTap，长按手势包在外层；两者在手势竞技场里分别是
          // tap / long-press，不会互相吞掉。
          return GestureDetector(
            onLongPress: () => onLongPress(item),
            child: cardBuilder(item, heroTagOf?.call(item)),
          );
        },
      ),
    );
  }
}
