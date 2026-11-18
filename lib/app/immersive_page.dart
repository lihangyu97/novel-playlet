import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前压栈的沉浸页数量：阅读页 / 播放页 / 设置页。
///
/// 设置云同步在远端有更新时，如果这个值 > 0 就只更新 etag、不 apply：
/// 阅读中换字号会重排、播放中换倍速会改当前速度、设置页被回填会让开关
/// 在指尖下跳动。详情 / 搜索 / 缓存中心不算沉浸页。
final immersivePageProvider = NotifierProvider<ImmersivePageController, int>(
  ImmersivePageController.new,
);

class ImmersivePageController extends Notifier<int> {
  @override
  int build() => 0;

  void enter() => state = state + 1;

  void leave() => state = state > 0 ? state - 1 : 0;
}

/// 把页面包一层，进入/退出时维护 [immersivePageProvider]。
///
/// 放在路由的 `builder` 里最省事：不用改阅读页/播放页/设置页自己的状态。
class ImmersivePageTracker extends ConsumerStatefulWidget {
  const ImmersivePageTracker({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ImmersivePageTracker> createState() =>
      _ImmersivePageTrackerState();
}

class _ImmersivePageTrackerState extends ConsumerState<ImmersivePageTracker> {
  bool _entered = false;
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // dispose 里不能再用 context 查祖先；这里先缓存容器引用。
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void initState() {
    super.initState();
    // 不能在 initState 里直接改 provider：Riverpod 会报 "modify while
    // building"。等首帧后再计数，页面若在首帧前就被 pop 则不需要 leave。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(immersivePageProvider.notifier).enter();
      _entered = true;
    });
  }

  @override
  void dispose() {
    final container = _container;
    if (_entered && container != null) {
      // dispose 本身也是 widget 生命周期，延后到微任务里再改 provider。
      Future<void>.microtask(() {
        try {
          container.read(immersivePageProvider.notifier).leave();
        } catch (_) {
          // 容器已销毁（退出 App/测试收尾）时忽略。
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
