import 'package:flutter/material.dart';

/// 保活壳：放进 [PageView] / [TabBarView] 的页面滑出视口后不销毁。
///
/// 滚动位置、搜索框内容、已加载列表都挂在子树 State 上，销毁后回来会重置；
/// 首页壳的两个底部 tab 与我的页的两个分类 tab 共用这一层。
class KeepAliveBox extends StatefulWidget {
  const KeepAliveBox({super.key, required this.child});

  final Widget child;

  @override
  State<KeepAliveBox> createState() => _KeepAliveBoxState();
}

class _KeepAliveBoxState extends State<KeepAliveBox>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
