import 'package:flutter/material.dart';

/// 封面 Hero 的 tag 规则。
///
/// 同一个路由里可能同时存在多份封面：推荐页三个分类被 `TabBarView` 保活、
/// 底栏两个页面被 `PageView` 保活，所以 tag 必须带「来源」维度，否则同一本书
/// 在推荐流和书架里各出现一次就会撞 tag（Hero 会直接抛断言）。详情页只认
/// 导航参数里带过来的那一个 tag，从而精确接上发起点击的那张卡片。
class CoverHeroTag {
  /// 小说封面。`source` 用「页面-入口」描述，例如 `recommend-novel`、
  /// `mine-shelf`。
  static String novel(String source, String id) => 'cover-novel-$source-$id';

  /// 短剧/漫剧封面。
  static String video(String source, String id) => 'cover-video-$source-$id';
}

/// 给封面套一层 [Hero]；[tag] 为 null 时原样返回。
///
/// 列表卡片与详情页封面都用它，保证两端的 Hero 子树结构一致。
class CoverHero extends StatelessWidget {
  const CoverHero({
    super.key,
    required this.tag,
    required this.child,
    this.flightShuttleBuilder,
  });

  final String? tag;
  final Widget child;

  /// 自定义飞行过程（例如详情页封面飞入时逐渐模糊成背景）。
  final HeroFlightShuttleBuilder? flightShuttleBuilder;

  @override
  Widget build(BuildContext context) {
    final tag = this.tag;
    if (tag == null) return child;
    return Hero(
      tag: tag,
      flightShuttleBuilder: flightShuttleBuilder,
      // iOS 边缘侧滑返回走的是「用户手势转场」；默认 Hero 在手势转场里不飞，
      // 打开后返回时也能看到封面缩回卡片。
      transitionOnUserGestures: true,
      child: child,
    );
  }
}

/// 把即将发起 Hero 飞行的卡片整块移进「内容可视区」。
///
/// Hero 的飞行层由 Navigator 插在 Overlay 最上层，盖住整个页面：底栏胶囊、
/// 顶部搜索框/分类 tabs 的 Stack 顺序再高也压不住它。所以这里不去调层级，而是
/// 让飞行本身不落进这些区域——
///
/// - 去程：卡片被滚出视口、或被悬浮底栏压住一部分时，封面从这些位置起飞会
///   直接画在底栏上面；
/// - 回程：降落目标是同一张卡片，它不在视口里时封面缩回去会飘在固定区外面，
///   看起来像「封面盖住了其它元素」。
///
/// 番茄的做法是进详情页后把对应 item 移进视口；这里在点击的同一帧做一次无动画
/// 位移（路由转场从同一帧开始，用户看到的是封面飞出，而不是列表跳动），
/// 起点与回程落点就都落在可视区里了。
///
/// 卡片已经完整可见时是 no-op：最常见的点击路径不会产生多余位移。
///
/// [bottomInset] 是被悬浮底栏盖住的高度（推荐页从外层壳子透传，取值见
/// `FloatingNavigationBar.totalHeight`）。
void revealHeroSource(BuildContext cardContext, {double bottomInset = 0}) {
  final card = cardContext.findRenderObject();
  if (card is! RenderBox || !card.hasSize) return;

  final scrollable = Scrollable.maybeOf(cardContext);
  if (scrollable == null) return;
  // 卡片能被点到就说明它已经在布局里：没有内容尺寸时宁可不动，也不要抛断言。
  final position = scrollable.position;
  if (!position.hasContentDimensions || !position.hasPixels) return;

  final viewport = scrollable.context.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return;

  // 全程用全局坐标：卡片可能被视口裁掉一截、也可能被底栏盖住，但布局位置是
  // 准的，比在滚动的局部坐标系里推算稳。
  final cardTop = card.localToGlobal(Offset.zero).dy;
  final cardBottom = cardTop + card.size.height;
  final visibleTop = viewport.localToGlobal(Offset.zero).dy;
  final visibleBottom = visibleTop + viewport.size.height - bottomInset;

  // 卡片比可视区还高时（超大字号等）优先保头部：对齐顶部，至少能看见封面。
  final double delta;
  if (cardTop < visibleTop) {
    delta = cardTop - visibleTop;
  } else if (cardBottom > visibleBottom) {
    delta = cardBottom - visibleBottom;
  } else {
    return;
  }
  // 亚像素抖动不值得滚一次（也避免和刷新/回弹动画抢滚动位置）。
  if (delta.abs() < 0.5) return;

  final offset = position.pixels + delta;
  final minOffset = position.minScrollExtent;
  final maxOffset = position.maxScrollExtent;
  final target = offset.clamp(minOffset, maxOffset).toDouble();
  if (target == position.pixels) return;
  position.jumpTo(target);
}
