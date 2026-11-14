import 'package:flutter/material.dart';

/// 全局滚动行为：所有平台都用夹紧（clamping）物理，不要 iOS 的橡皮筋回弹。
///
/// 小说推荐页的下拉刷新仍然有效：RefreshIndicator 依赖的是边缘拖拽产生的
/// OverscrollNotification，clamping 物理同样会发。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  /// 关掉 Material 3 在 Android 上默认加的拉伸指示器。
  ///
  /// `ClampingScrollPhysics` 只限制内容越界，Android 12+ 仍会把整个滚动视图
  /// 拉长一下（stretch overscroll）；iOS 本来就不画这个指示器。这里统一返回
  /// [child]，让详情页/弹层/所有列表在两端都没有橡皮筋观感。
  /// RefreshIndicator 和阅读器依赖的 OverscrollNotification 不受影响。
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
