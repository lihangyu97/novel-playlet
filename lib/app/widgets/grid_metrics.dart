import 'dart:math' as math;

/// 网格里一张卡的宽度：可用宽度减去 `columns - 1` 个列间距后均分。
///
/// 我的页书架/收藏与推荐页瀑布流共用；搜索结果为「3.5 张卡 + 右侧露半张」
/// 的预览布局，是另一套留白口径，不用这个函数。
double gridCellWidth({
  required double availableWidth,
  required int columns,
  double spacing = 8,
}) {
  if (columns <= 0) return 0;
  return math.max(0, (availableWidth - spacing * (columns - 1)) / columns);
}
