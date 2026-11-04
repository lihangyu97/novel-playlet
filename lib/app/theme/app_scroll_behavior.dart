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
}
