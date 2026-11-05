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
