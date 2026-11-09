import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import 'mine_drama_providers.dart';
import 'widgets/mine_drama_panel.dart';
import 'widgets/mine_novel_panel.dart';

/// 面板切换的时间轴：最近阅读/观看块 0ms 起步、标题块 100ms、书架/收藏块
/// 200ms，每块自己滑 300ms，所以总时间轴 500ms（见 StaggeredBlock 的窗口换算）。
const _panelTimeline = Duration(milliseconds: 500);

/// 横滑甩过这个速度就直接翻页，不再看拖拽比例。
const _panelSwipeVelocity = 300.0;

/// 我的：小说 / 短剧 两块面板，右下角悬浮按钮或左右滑动切换。
///
/// 两个面板是同一套版式的镜像：小说的标题/图标在左、设置按钮在右；短剧反过来
/// （标题/图标在右、设置在左）。切换时不是整页一起平移，而是分三块穿插着
/// 滑出/滑入（最近阅读/观看 0ms、标题 100ms、书架/收藏 200ms 延迟）。
///
/// 小说侧数据全部在本地（书架 + 阅读进度）；短剧侧的收藏/观看记录还没做，
/// 先用 [mineDramaDataProvider] 的空列表占位，页面结构与交互按最终形态搭好。
class MinePage extends ConsumerStatefulWidget {
  const MinePage({super.key, this.bottomInset = 0});

  /// 悬浮底栏遮住的高度（外层 shell 传进来）；列表末尾多留这么多空白。
  final double bottomInset;

  /// 测试/无障碍定位用（两个面板 + 切换按钮）。
  static const novelPanelKey = Key('mine-panel-novel');
  static const dramaPanelKey = Key('mine-panel-drama');
  static const switchButtonKey = Key('mine-panel-switch');

  @override
  ConsumerState<MinePage> createState() => _MinePageState();
}

class _MinePageState extends ConsumerState<MinePage>
    with SingleTickerProviderStateMixin {
  /// 0 = 小说，1 = 短剧；拖拽过程中只有松手才更新它。
  int _panel = 0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _panelTimeline,
    value: 0,
  );

  bool get _showingDrama => _panel == 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSettings() {
    context.pushAppRoute(const SettingsRoute());
  }

  void _togglePanel() => _animateTo(_panel == 1 ? 0 : 1);

  /// 收尾到某一侧：按剩余进度折算时长，保证分块延迟的节奏不被打乱。
  void _animateTo(int target) {
    final remaining = (target - _controller.value).abs();
    if (target != _panel) setState(() => _panel = target);
    if (remaining < 0.001) return;
    final millis = math.max(
      120,
      (_panelTimeline.inMilliseconds * remaining).round(),
    );
    _controller.animateTo(
      target.toDouble(),
      duration: Duration(milliseconds: millis),
      curve: Curves.easeOutCubic,
    );
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _controller.stop();
  }

  /// 直接拖拽：手指移动多少，时间轴就走多少，分块窗口让它自然错开。
  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _controller.value = (_controller.value - details.delta.dx / width).clamp(
      0.0,
      1.0,
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() > _panelSwipeVelocity) {
      // 往左甩 = 看下一块（短剧），往右甩 = 回小说。
      _animateTo(velocity < 0 ? 1 : 0);
      return;
    }
    _animateTo(_controller.value >= 0.5 ? 1 : 0);
  }

  /// 只有停在某一端时才允许该面板接收滚动/点击；拖拽和动画过程中两边都锁住，
  /// 避免滑动一半时误滚某个列表。
  bool _isSettledAt(int index) {
    if (_controller.isAnimating) return false;
    return index == 0 ? _controller.value <= 0.001 : _controller.value >= 0.999;
  }

  @override
  Widget build(BuildContext context) {
    // 预取短剧侧数据：如果等切换时才第一次 watch，滑入过程中会闪一下
    // 「正在读取…」。小说侧也是进页面就读，两边保持一致。
    //
    // 用 listen 而不是 watch：这里只关心"把 provider 拉起来"，数据变化由
    // 各自的 MineNovelPanel / MineDramaPanel 自己 watch 消费。若用 watch，
    // 看剧存进度会让整个 MinePage（含两个面板、两个动画控制器、设置按钮）
    // 重建一次，而它还在 PageView 里 keep-alive，看不见时也照建。
    ref.listen(mineDramaDataProvider, (_, _) {});
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              child: Stack(
                children: [
                  _panelSurface(
                    index: 0,
                    child: MineNovelPanel(
                      key: MinePage.novelPanelKey,
                      bottomInset: widget.bottomInset,
                      progress: _controller,
                    ),
                  ),
                  _panelSurface(
                    index: 1,
                    child: MineDramaPanel(
                      key: MinePage.dramaPanelKey,
                      bottomInset: widget.bottomInset,
                      progress: _controller,
                    ),
                  ),
                ],
              ),
            ),
            // 唯一一个设置按钮：小说面板时在右、短剧面板时在左，切换过程中
            // 跟着 _controller 在屏幕内左右移动（不会被滑出屏幕）。
            Positioned(
              top: 20,
              left: 8,
              right: 8,
              height: 40,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Align(
                    alignment: Alignment(1 - 2 * _controller.value, 0),
                    child: child,
                  );
                },
                child: IconButton(
                  onPressed: _openSettings,
                  tooltip: '设置',
                  visualDensity: VisualDensity.compact,
                  iconSize: 22,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
            ),
            // 右下角只剩面板切换按钮：缓存入口已挪到推荐页搜索框右侧的
            // 「已缓存」按钮，不再悬浮在这一页（避免和胶囊/切换按钮挤在一起）。
            Positioned(
              right: 8,
              bottom: widget.bottomInset + 16,
              child: _PanelSwitchButton(
                key: MinePage.switchButtonKey,
                showingDrama: _showingDrama,
                onTap: _togglePanel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelSurface({required int index, required Widget child}) {
    return AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, child) {
        final settled = _isSettledAt(index);
        return IgnorePointer(
          ignoring: !settled,
          child: ExcludeSemantics(excluding: !settled, child: child),
        );
      },
    );
  }
}

/// 悬浮切换按钮：当前看小说时显示短剧图标（点它去短剧），反之亦然。
class _PanelSwitchButton extends StatelessWidget {
  const _PanelSwitchButton({
    super.key,
    required this.showingDrama,
    required this.onTap,
  });

  final bool showingDrama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = showingDrama
        ? Icons.auto_stories_rounded
        : Icons.theaters_rounded;
    final label = showingDrama ? '看小说' : '看短剧';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: scheme.primary,
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: Colors.black38,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: 24,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
