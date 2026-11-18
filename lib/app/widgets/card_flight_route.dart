import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';

import '../../core/cache/app_image_cache.dart';
import '../theme/app_theme.dart';
import 'novel_cover.dart';

/// 卡片矩形解析器。
///
/// push 时取一次当起点；pop 时动画每帧再取一次——列表可能被 `revealHeroSource`
/// 滚过，落点必须用卡片**现在**的位置。卡片已被回收时返回 null，转场退化成
/// 「原地淡入淡出」。
typedef CardRectResolver = Rect? Function();

/// 卡片矩形的「活解析器」：pop 时再取一次，卡片已被回收就返回 null。
///
/// [context] 是卡片自己的 Element：`findRenderObject` 拿到的是卡片的绘制
/// 盒子（含内边距的实际视觉边界），`localToGlobal` 换成屏幕坐标。
CardRectResolver cardRectResolver(BuildContext context) {
  return () {
    if (!context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  };
}

/// 正在跑卡片式转场的路由数。
///
/// 大于 0 时，下层普通路由不再做 iOS 的「视差位移」——否则卡片放大的同时
/// 列表还在往左滑（那是下层路由自己的 secondaryAnimation 干的事）。
final ValueNotifier<int> cardExpandTransitionsActive = ValueNotifier<int>(0);

/// 普通页面（阅读页、设置、排行榜…）的转场：保持 iOS 的 Cupertino 滑入，
/// 只在卡片式转场进行时把下层视差关掉。只注册到 iOS/macOS。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      CupertinoPageTransition.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: cardExpandTransitionsActive,
      builder: (context, active, _) {
        return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
          route,
          context,
          animation,
          active > 0 ? kAlwaysDismissedAnimation : secondaryAnimation,
          child,
        );
      },
    );
  }
}

/// 详情页里「飞行元素」落地的目标位置。
///
/// 由路由创建、随 pageBuilder 传给详情页：详情页把 [coverKey] / [titleKey] /
/// [subtitleKey] / [scoreKey] 挂到对应的 widget 上，路由在转场开始时量出它们的
/// 矩形，第二阶段的飞行就往这些矩形上落。
///
/// [progress] 是路由动画（0→1）：详情页自己的封面和标题在飞行期间要隐身，
/// 等飞行元素落地（[landed] 接近 1）再显形，否则会出现「页面封面 + 飞的封面」
/// 两份。
class DetailFlightTargets {
  DetailFlightTargets(this.progress, {this.active = true});

  /// 路由动画（push 0→1，pop 1→0）。
  final Animation<double> progress;

  /// 是否真的在做卡片快照飞行。没有卡片形态（榜单行/缓存条目/深链）时为
  /// false：详情页的封面/标题不能隐身，否则没有飞行元素来接管。
  final bool active;

  final GlobalKey coverKey = GlobalKey();
  final GlobalKey titleKey = GlobalKey();
  final GlobalKey subtitleKey = GlobalKey();
  final GlobalKey scoreKey = GlobalKey();

  /// 第二阶段进度：0 = 刚开始飞，1 = 全部落位。
  double get secondPhase {
    final v = progress.value;
    if (v <= 0.5) return 0;
    return ((v - 0.5) / 0.5).clamp(0.0, 1.0);
  }

  /// 详情页自己的封面/标题何时显形：飞行元素快落位时淡入，交接不跳。
  double get ownedContentOpacity {
    if (!active) return 1;
    final b = secondPhase;
    if (b <= 0.85) return 0;
    return ((b - 0.85) / 0.15).clamp(0.0, 1.0);
  }

  Rect? rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// 卡片快照：第一阶段要还原的卡片内容。
///
/// 快照是「按数据重画的一张卡片」：白底/封面/标题/作者/评分角标/推荐理由
/// 角标。第一段把它从列表卡片的位置等比放大到屏宽的 [phaseOneWidthRatio]，
/// 布局不动；第二段再把里面几个元素拆出来飞向详情页。
class CardFlightData {
  const CardFlightData({
    required this.rect,
    required this.cover,
    required this.title,
    this.meta = '',
    this.score = '',
    this.badge = '',
    this.coverAspect = kNovelCoverAspect,
    this.coverRadius = AppTheme.mediaCardRadius,
    this.surface = true,
  });

  /// 卡片矩形（pop 时会被再次调用，拿到卡片当时的位置）。
  final CardRectResolver rect;

  final String cover;
  final String title;

  /// 作者（短剧是「全 N 集」）。
  final String meta;

  /// 原始分数字符串；空 = 不画评分角标。
  final String score;

  /// 推荐理由角标（封面左上角）；空 = 不画。
  final String badge;

  /// 封面高 / 宽。小说 4:3、短剧 ≈10:7。
  final double coverAspect;

  /// 封面圆角（卡片化封面由外框裁切，传 0）。
  final double coverRadius;

  /// 是否画成白底卡片（推荐流/搜索结果/收藏都是；榜单行不是）。
  final bool surface;
}

/// 从列表卡片「长出来」的详情页路由（两段式容器变换）。
///
/// 第一段 0→0.5：卡片快照等比放大到屏宽的 [phaseOneWidthRatio]（比例不变、
/// 布局不动），详情页不可见。
/// 第二段 0.5→1：快照里的封面/标题/作者/评分从放大后的位置飞到详情页对应
/// 位置，同时详情页内容淡入；元素落位后由详情页自己的封面/标题接管。
/// 返回严格反向。
class CardFlightRoute<T> extends PageRoute<T> {
  CardFlightRoute({required this.pageBuilder, this.data, super.settings});

  /// 第一段结束时卡片占屏宽的比例。
  static const double phaseOneWidthRatio = 0.75;

  static const Duration forwardDuration = Duration(milliseconds: 520);
  static const Duration reverseDuration = Duration(milliseconds: 460);

  /// 构建详情页；[targets] 要传给页面，页面把落点 key 挂到自己的封面/标题上。
  final Widget Function(BuildContext context, DetailFlightTargets targets)
  pageBuilder;

  /// 卡片快照数据；null = 这一条没有卡片形态（榜单行/缓存条目），退化成淡入。
  final CardFlightData? data;

  DetailFlightTargets? _targets;

  CardRectResolver? get rect => data?.rect;

  bool _holdingSecondary = false;
  NavigatorState? _gestureNavigator;

  @override
  Duration get transitionDuration => forwardDuration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  @override
  bool get opaque => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final targets = _targets ??= DetailFlightTargets(
      animation,
      active: data != null,
    );
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: pageBuilder(context, targets),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _EdgeSwipeBack(
      route: this,
      child: _CardFlightTransition(
        route: this,
        animation: animation,
        targets: _targets,
        child: child,
      ),
    );
  }

  @override
  void install() {
    super.install();
    animation?.addStatusListener(_handleStatusChanged);
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_handleStatusChanged);
    _releaseSecondary();
    super.dispose();
  }

  void _handleStatusChanged(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        _holdSecondary();
      case AnimationStatus.completed:
      case AnimationStatus.dismissed:
        _releaseSecondary();
    }
  }

  void _holdSecondary() {
    if (_holdingSecondary) return;
    _holdingSecondary = true;
    cardExpandTransitionsActive.value += 1;
  }

  void _releaseSecondary() {
    if (!_holdingSecondary) return;
    _holdingSecondary = false;
    cardExpandTransitionsActive.value = math.max(
      0,
      cardExpandTransitionsActive.value - 1,
    );
  }

  bool get swipeBackEnabled => popGestureEnabled && isCurrent;

  void beginSwipeBack() {
    final controller = this.controller;
    if (controller == null) return;
    _gestureNavigator = navigator;
    controller.stop();
    _gestureNavigator?.didStartUserGesture();
  }

  void updateSwipeBack(double delta) {
    final controller = this.controller;
    if (controller == null) return;
    controller.value = (controller.value - delta).clamp(0.0, 1.0);
  }

  void endSwipeBack(double velocity) {
    final controller = this.controller;
    if (controller == null) return;
    final navigator = _gestureNavigator ?? this.navigator;
    const minFlingVelocity = 1.0;

    final bool animateForward;
    if (!isCurrent) {
      animateForward = isActive;
    } else if (velocity.abs() >= minFlingVelocity) {
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      _animateSwipe(controller, 1.0);
      return;
    }
    if (isCurrent) navigator?.pop();
    if (controller.isAnimating) {
      _animateSwipe(controller, 0.0);
    } else {
      _stopUserGesture();
    }
  }

  void _animateSwipe(AnimationController controller, double target) {
    // 反向收尾必须用 animateBack：animateTo 会把方向重置成 forward，路由
    // 永远到不了 dismissed、也就不会被 Navigator finalize 掉。
    if (target >= controller.value) {
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.fastEaseInToSlowEaseOut,
      );
    } else {
      controller.animateBack(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.fastEaseInToSlowEaseOut,
      );
    }
    late final AnimationStatusListener listener;
    listener = (AnimationStatus _) {
      final status = controller.status;
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      controller.removeStatusListener(listener);
      _stopUserGesture();
    };
    controller.addStatusListener(listener);
  }

  void _stopUserGesture() {
    final navigator = _gestureNavigator;
    _gestureNavigator = null;
    if (navigator != null && navigator.mounted) {
      navigator.didStopUserGesture();
    }
  }
}

/// 第一段那张卡片快照（测试用来断言它是等比放大的）。
const Key cardCloneKey = ValueKey('card-flight-clone');

/// 页面整体的透明度层（测试用来断言「第一段看不到页面」）。
const Key pageOpacityKey = ValueKey('card-flight-page');

/// 卡片快照里可以被单独拆出来飞的元素。
enum _FlightPart { cover, title, meta, score }

class _CardFlightTransition extends StatefulWidget {
  const _CardFlightTransition({
    required this.route,
    required this.animation,
    required this.targets,
    required this.child,
  });

  final CardFlightRoute<dynamic> route;
  final Animation<double> animation;
  final DetailFlightTargets? targets;
  final Widget child;

  @override
  State<_CardFlightTransition> createState() => _CardFlightTransitionState();
}

class _CardFlightTransitionState extends State<_CardFlightTransition> {
  final GlobalKey _shellKey = GlobalKey();
  final GlobalKey _coverKey = GlobalKey();
  final GlobalKey _titleKey = GlobalKey();
  final GlobalKey _metaKey = GlobalKey();
  final GlobalKey _scoreKey = GlobalKey();

  /// 卡片起始矩形（screen 坐标）。
  Rect? _cardRect;

  /// 各元素在卡片本地坐标里的矩形（相对卡片左上角）。
  Map<_FlightPart, Rect> _local = const {};

  /// 各元素在详情页里的目标矩形。
  Map<_FlightPart, Rect> _target = const {};

  bool _measured = false;

  @override
  void initState() {
    super.initState();
    _cardRect = widget.route.rect?.call();
    // 第一帧之后量：卡片快照（本地坐标）和详情页里对应元素的位置。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted || _measured) return;
    final shell = _shellKey.currentContext?.findRenderObject();
    final cardRect = _cardRect ?? widget.route.rect?.call();
    if (shell is! RenderBox || !shell.hasSize || cardRect == null) {
      // 还没布局好（或卡片没了）：下一帧再试一次，最多几次就放弃。
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
      return;
    }
    final origin = shell.localToGlobal(Offset.zero);
    Rect? localOf(GlobalKey key) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      final global = box.localToGlobal(Offset.zero) & box.size;
      return global.shift(-origin);
    }

    final cover = localOf(_coverKey);
    final title = localOf(_titleKey);
    final meta = localOf(_metaKey);
    final score = localOf(_scoreKey);

    final targets = widget.targets;
    final target = <_FlightPart, Rect>{};
    if (targets != null) {
      final tCover = targets.rectOf(targets.coverKey);
      final tTitle = targets.rectOf(targets.titleKey);
      final tSubtitle = targets.rectOf(targets.subtitleKey);
      final tScore = targets.rectOf(targets.scoreKey);
      if (tCover != null) target[_FlightPart.cover] = tCover;
      if (tTitle != null) target[_FlightPart.title] = tTitle;
      if (tSubtitle != null) target[_FlightPart.meta] = tSubtitle;
      if (tScore != null) target[_FlightPart.score] = tScore;
    }

    if (cover == null || title == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
      return;
    }
    final local = <_FlightPart, Rect>{
      _FlightPart.cover: cover,
      _FlightPart.title: title,
    };
    if (meta != null) local[_FlightPart.meta] = meta;
    if (score != null) local[_FlightPart.score] = score;
    setState(() {
      _cardRect = cardRect;
      _local = local;
      _target = target;
      _measured = true;
    });
  }

  /// 第一段结束时的卡片矩形：等比放大到屏宽 75%，水平居中、顶部对齐。
  Rect _phaseOneEnd(Rect cardRect, Size screen) {
    final width = screen.width * CardFlightRoute.phaseOneWidthRatio;
    final scale = width / cardRect.width;
    final height = cardRect.height * scale;
    return Rect.fromLTWH(
      (screen.width - width) / 2,
      cardRect.top,
      width,
      height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final size = MediaQuery.sizeOf(context);
    final targets = widget.targets;

    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (context, child) {
        final v = widget.animation.value;
        // 注意不能用 `v >= 1`：路由首帧会以进度 1.0 先建一次（Hero 量位用），
        // 那时动画状态还是 forward。
        if (widget.animation.isCompleted) return child!;
        final live = widget.route.rect?.call();
        if (live != null) _cardRect = live;
        final cardRect = _cardRect;
        // 页面本体：第一段完全不可见；第二段开始淡入。
        final pageOpacity = reduceMotion
            ? 1.0
            : Curves.easeIn.transform(((v - 0.5) / 0.45).clamp(0.0, 1.0));
        final data = widget.route.data;
        // 没有卡片形态（榜单行/缓存条目）、或量不到卡片（深链/卡片已回收）：
        // 直接淡入页面，不做容器变换。
        if (data == null || cardRect == null) {
          return Opacity(
            key: pageOpacityKey,
            opacity: reduceMotion ? 1 : Curves.easeIn.transform(v),
            child: child,
          );
        }

        final rectA = _phaseOneEnd(cardRect, size);
        // 第一段 / 第二段进度（都是 0→1）。
        final a = Curves.easeInOutCubic.transform((v / 0.5).clamp(0.0, 1.0));
        final b = ((v - 0.5) / 0.5).clamp(0.0, 1.0);
        final scaleAB = rectA.width / cardRect.width;
        // 还没量完（首帧）时也要把快照渲染出来：量它自己的部件位置要靠它。
        // 进入第二段后快照还要留 15%：白底/文字淡出、飞行元素接着走，不会
        // 出现「白卡片突然消失」的一帧。
        final cloneFade = _measured ? 1 - (b / 0.15).clamp(0.0, 1.0) : 0.0;
        final showClone = !_measured || cloneFade > 0;
        final cloneRect = Rect.lerp(cardRect, rectA, a)!;

        final backdropColor = Theme.of(context).scaffoldBackgroundColor;
        // 第二段一开始就让页面底色不透明：只淡入内容，否则列表会从文字缝里
        // 透出来，整页看起来蒙了一层灰。
        final backdropOpacity = Curves.easeOut.transform(
          (b / 0.18).clamp(0.0, 1.0),
        );

        return Material(
          // 飞行层不在任何 Scaffold 里：Text 没有 Material 祖先时 debug 会画
          // 黄色下划线。必须把整层包进来（垫兄弟节点没用，文字不是它的后代）。
          type: MaterialType.transparency,
          child: Stack(
            children: [
              if (backdropOpacity > 0)
                Positioned.fill(
                  child: Opacity(
                    opacity: backdropOpacity,
                    child: ColoredBox(color: backdropColor),
                  ),
                ),
              Positioned.fill(
                child: Opacity(
                  key: pageOpacityKey,
                  opacity: pageOpacity,
                  child: child,
                ),
              ),
              if (showClone)
                Positioned(
                  left: cloneRect.left,
                  top: cloneRect.top,
                  child: IgnorePointer(
                    ignoring: !_measured,
                    child: Opacity(
                      opacity: cloneFade,
                      child: Transform.scale(
                        key: cardCloneKey,
                        scale: cloneRect.width / cardRect.width,
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          key: _shellKey,
                          width: cardRect.width,
                          child: _FlightCard(
                            data: data,
                            coverKey: _coverKey,
                            titleKey: _titleKey,
                            metaKey: _metaKey,
                            scoreKey: _scoreKey,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_measured && b > 0)
                ..._secondPhaseParts(rectA, scaleAB, b, targets),
            ],
          ),
        );
      },
    );
  }

  /// 第二段：快照里的元素从「放大后的卡片位置」飞到详情页对应位置。
  List<Widget> _secondPhaseParts(
    Rect rectA,
    double scaleAB,
    double b,
    DetailFlightTargets? targets,
  ) {
    final eased = Curves.easeInOutCubic.transform(b);
    final parts = <Widget>[];
    for (final entry in _local.entries) {
      final target = _target[entry.key];
      if (target == null) continue;
      final start = Rect.fromLTWH(
        rectA.left + entry.value.left * scaleAB,
        rectA.top + entry.value.top * scaleAB,
        entry.value.width * scaleAB,
        entry.value.height * scaleAB,
      );
      final rect = Rect.lerp(start, target, eased)!;
      parts.add(
        Positioned.fromRect(
          rect: rect,
          child: _partWidget(entry.key, rect, start, target, eased, b),
        ),
      );
    }
    return parts;
  }

  Widget _partWidget(
    _FlightPart part,
    Rect rect,
    Rect start,
    Rect target,
    double eased,
    double b,
  ) {
    final data = widget.route.data!;
    // 卡片在白底上、详情页在页面底色上：封面保持图片，文字/角标在最后
    // 15% 淡出，交给详情页自己的那份接管（落位时位置已经重合）。
    final handoff = ((b - 0.85) / 0.15).clamp(0.0, 1.0);
    final opacity = 1 - handoff;
    switch (part) {
      case _FlightPart.cover:
        return Opacity(
          opacity: opacity,
          child: _FlightCover(
            url: data.cover,
            width: rect.width,
            height: rect.height,
          ),
        );
      case _FlightPart.title:
        return Opacity(
          opacity: opacity,
          child: _FlightText(
            text: data.title,
            fontSize: 22 * eased + 15 * (1 - eased),
            color: const Color(0xFF14181B),
            weight: FontWeight.w700,
            width: rect.width,
          ),
        );
      case _FlightPart.meta:
        return Opacity(
          opacity: opacity,
          child: _FlightText(
            text: data.meta,
            fontSize: 14 * eased + 12 * (1 - eased),
            color: const Color(0xFF5A6268),
            weight: FontWeight.w400,
            width: rect.width,
          ),
        );
      case _FlightPart.score:
        return Opacity(
          opacity: opacity,
          child: _FlightText(
            text: data.score,
            fontSize: 14 * eased + 11 * (1 - eased),
            color: const Color(0xFF14181B),
            weight: FontWeight.w600,
            width: rect.width,
          ),
        );
    }
  }
}

/// 飞行中的封面。
///
/// 解码尺寸固定成屏幕宽（不随飞行矩形变化）：`NovelCover` 会按传入宽度算
/// `memCacheWidth`，尺寸每帧变就等于每帧重新解码，真机上表现为封面闪烁。
class _FlightCover extends StatelessWidget {
  const _FlightCover({
    required this.url,
    required this.width,
    required this.height,
    this.radius = 0,
  });

  final String url;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final decodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context) *
                1.5)
            .round();
    if (url.isEmpty) {
      return SizedBox(
        width: width,
        height: height,
        child: const ColoredBox(color: Color(0x22808080)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: CachedNetworkImage(
          imageUrl: url,
          cacheManager: AppImageCache.manager,
          fit: BoxFit.cover,
          memCacheWidth: decodeWidth,
          maxWidthDiskCache: 1440,
          fadeInDuration: Duration.zero,
          placeholder: (_, _) => const ColoredBox(color: Color(0x22808080)),
          errorWidget: (_, _, _) => const ColoredBox(color: Color(0x22808080)),
        ),
      ),
    );
  }
}

/// 第二段里单独飞行的文字：按飞行矩形的宽度换行、字号线性插值。
class _FlightText extends StatelessWidget {
  const _FlightText({
    required this.text,
    required this.fontSize,
    required this.color,
    required this.weight,
    required this.width,
  });

  final String text;
  final double fontSize;
  final Color color;
  final FontWeight weight;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      child: Text(
        text,
        maxLines: 3,
        softWrap: true,
        overflow: TextOverflow.visible,
        style: TextStyle(fontSize: fontSize, color: color, fontWeight: weight),
      ),
    );
  }
}

/// 第一段的卡片快照：白底卡片 + 封面 + 标题 + 作者 + 两个角标。
///
/// 布局与 `MediaCard` 的卡片化形态同口径（封面满宽出血、文字区 10/8/10、
/// 标题 2 行、元信息 1 行），放大时整块等比缩放、布局不动。
class _FlightCard extends StatelessWidget {
  const _FlightCard({
    required this.data,
    required this.coverKey,
    required this.titleKey,
    required this.metaKey,
    required this.scoreKey,
  });

  final CardFlightData data;
  final GlobalKey coverKey;
  final GlobalKey titleKey;
  final GlobalKey metaKey;
  final GlobalKey scoreKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _build(context, constraints.maxWidth),
    );
  }

  Widget _build(BuildContext context, double width) {
    final theme = Theme.of(context);
    final coverHeight = data.coverAspect * width;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: coverKey,
          height: coverHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: _FlightCover(
                  url: data.cover,
                  width: width,
                  height: coverHeight,
                  radius: data.surface ? 0 : data.coverRadius,
                ),
              ),
              if (data.badge.isNotEmpty)
                Positioned(top: 6, left: 6, child: _FlightBadge(data.badge)),
              if (data.score.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _FlightBadge('${data.score}分'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: titleKey,
                child: Text(
                  data.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (data.meta.isNotEmpty) ...[
                const SizedBox(height: 3),
                SizedBox(
                  key: metaKey,
                  child: Text(
                    data.meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return data.surface
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppTheme.mediaCardRadius),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.mediaCardRadius),
              child: content,
            ),
          )
        : content;
  }
}

class _FlightBadge extends StatelessWidget {
  const _FlightBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.15,
        ),
      ),
    );
  }
}

/// iOS 式边缘侧滑返回：拖动直接驱动转场进度。
class _EdgeSwipeBack extends StatefulWidget {
  const _EdgeSwipeBack({required this.route, required this.child});

  final CardFlightRoute<dynamic> route;
  final Widget child;

  @override
  State<_EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<_EdgeSwipeBack> {
  static const double _edgeWidth = 20;

  late final HorizontalDragGestureRecognizer _recognizer =
      HorizontalDragGestureRecognizer(debugOwner: this)
        ..onStart = _handleDragStart
        ..onUpdate = _handleDragUpdate
        ..onEnd = _handleDragEnd
        ..onCancel = _handleDragCancel;

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.route.swipeBackEnabled) {
      _recognizer.addPointer(event);
    }
  }

  void _handleDragStart(DragStartDetails details) {
    widget.route.beginSwipeBack();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final width = context.size?.width ?? 1;
    widget.route.updateSwipeBack((details.primaryDelta ?? 0) / width);
  }

  void _handleDragEnd(DragEndDetails details) {
    final width = context.size?.width ?? 1;
    widget.route.endSwipeBack(details.velocity.pixelsPerSecond.dx / width);
  }

  void _handleDragCancel() => widget.route.endSwipeBack(0);

  @override
  Widget build(BuildContext context) {
    final width = math.max(MediaQuery.paddingOf(context).left, _edgeWidth);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          width: width,
          top: 0,
          bottom: 0,
          child: Listener(
            onPointerDown: _handlePointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}
