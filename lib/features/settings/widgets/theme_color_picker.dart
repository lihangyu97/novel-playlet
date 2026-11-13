import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/app_bottom_sheet.dart';

/// 底部的自定义颜色弹层：HSV 取色（色相条 + 饱和度/明度面板）。
///
/// 为什么自己画：项目不允许新增依赖，也没有系统取色器可用；HSV 比 RGB
/// 滑块更符合「挑一个主色」的直觉——先定色相，再调深浅。
///
/// 主题色与阅读页「对话高亮」色共用这个弹层：调用方传 [title] 与
/// [previewBuilder] 就能把预览区换成自己的示例（主题色默认预览按钮/强调色，
/// 对话高亮预览一段正文）。预览会跟随当前取色更新：拖动时色块/十六进制
/// 逐帧变化，预览区（ThemeData / 分页）按 ~90ms 合并，避免每帧重活。
///
/// 注意 `enableDrag: false`：弹层默认的纵向拖动手势会和取色面板打架，而且
/// sheet 的 VerticalDrag 更早接受（约 18pt，子级 Pan 要 36pt），结果是
/// 「拖明度」变成「拖弹层」，明度根本调不动。这里关掉 sheet 拖动。
Future<Color?> showThemeColorPicker(
  BuildContext context, {
  required Color initial,
  String title = '自定义主题色',
  Widget Function(Color color)? previewBuilder,
}) {
  return showAppBottomSheet<Color>(
    context: context,
    enableDrag: false,
    builder: (_) => ThemeColorPickerSheet(
      initial: initial,
      title: title,
      previewBuilder: previewBuilder,
    ),
  );
}

class ThemeColorPickerSheet extends StatefulWidget {
  const ThemeColorPickerSheet({
    super.key,
    required this.initial,
    this.title = '自定义主题色',
    this.previewBuilder,
  });

  final Color initial;
  final String title;

  /// 自定义预览区；null = 主题色默认预览（按钮 + 强调色）。
  final Widget Function(Color color)? previewBuilder;

  @override
  State<ThemeColorPickerSheet> createState() => _ThemeColorPickerSheetState();
}

class _ThemeColorPickerSheetState extends State<ThemeColorPickerSheet> {
  /// 预览用的颜色合并间隔。
  ///
  /// 预览里主体色卡的 ThemeData 与对话高亮示例的分页都比较贵，而拖动
  /// SV 面板/色相条时每个 pointer move 都会 setState；这里把**预览**的
  /// 颜色更新合并到 ~11fps，色块与十六进制仍逐帧即时更新。
  static const _previewThrottle = Duration(milliseconds: 90);

  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  /// 预览当前显示的颜色（可能滞后 [_previewThrottle]）。
  late Color _previewColor = _hsv.toColor();

  Timer? _previewTimer;

  Color get _color => _hsv.toColor();

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  /// 拖动取色：色块/hex 立即更新，预览按 [_previewThrottle] 合并。
  void _updateHsv(HSVColor next) {
    if (next == _hsv) return;
    setState(() => _hsv = next);
    _previewTimer?.cancel();
    _previewTimer = Timer(_previewThrottle, () {
      if (!mounted) return;
      final color = _color;
      if (color == _previewColor) return;
      setState(() => _previewColor = color);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppBottomSheet(
      title: widget.title,
      closeTooltip: '关闭取色',
      // 小屏/大字号时内容可能超出可用高度：包一层滚动，别把按钮挤出屏幕。
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 当前候选中色：色块 + 十六进制，靠右排在标题下面一行。
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _ColorChip(color: _color, size: 22),
                const SizedBox(width: 8),
                Text(
                  _hexOf(_color),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SaturationValuePanel(hsv: _hsv, onChanged: _updateHsv),
            const SizedBox(height: 16),
            _HueBar(
              hue: _hsv.hue,
              onChanged: (hue) => _updateHsv(_hsv.withHue(hue)),
            ),
            const SizedBox(height: 20),
            widget.previewBuilder?.call(_previewColor) ??
                _ThemePreview(
                  seed: _previewColor,
                  brightness: theme.brightness,
                ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    // 与「确定」用同一套小圆角：M3 默认 OutlinedButton 是
                    // StadiumBorder，和 FilledButton 的 12 圆角并排会一大一小。
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_color),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 用当前候选中色现场生成一套主题，看一眼按钮/强调色长什么样。
///
/// 直接给页面换色会太跳（而且取消还要回滚），所以只在这里做局部预览。
///
/// 外层取色弹层每帧都会重建（hex 文本等），而 `AppTheme.themed` 里的
/// `ColorScheme.fromSeed` 是这条链路里最贵的一步：这里按 (seed, brightness)
/// memo 住 ThemeData，颜色没变时直接复用，不再重复派生动态配色。
class _ThemePreview extends StatefulWidget {
  const _ThemePreview({required this.seed, required this.brightness});

  final Color seed;
  final Brightness brightness;

  @override
  State<_ThemePreview> createState() => _ThemePreviewState();
}

class _ThemePreviewState extends State<_ThemePreview> {
  ThemeData? _theme;
  Color? _themeSeed;
  Brightness? _themeBrightness;

  ThemeData get _previewTheme {
    final cached = _theme;
    if (cached != null &&
        _themeSeed == widget.seed &&
        _themeBrightness == widget.brightness) {
      return cached;
    }
    final theme = AppTheme.themed(widget.seed, widget.brightness);
    _theme = theme;
    _themeSeed = widget.seed;
    _themeBrightness = widget.brightness;
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      // 用完整 ThemeData（而不是 copyWith(colorScheme:)）：copyWith 会把外层
      // 的 AppAccent 扩展原样留下，嵌套主题里的 accentOf 就会读到旧 seed。
      child: Theme(
        data: _previewTheme,
        child: Builder(
          builder: (context) {
            final previewScheme = Theme.of(context).colorScheme;
            return Row(
              children: [
                FilledButton(
                  onPressed: () {},
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                  child: const Text('主按钮'),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: previewScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '强调色',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: previewScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 饱和度（横）× 明度（竖）面板。
class _SaturationValuePanel extends StatelessWidget {
  const _SaturationValuePanel({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  static const double _height = 190;

  /// 测试要按 key 拖它：纵向拖动必须改变明度（曾经被 sheet 手势抢走）。
  static const Key panelKey = Key('theme-color-sv-panel');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, _height);
        void update(Offset local) {
          final s = (local.dx / size.width).clamp(0.0, 1.0);
          final v = (1 - local.dy / size.height).clamp(0.0, 1.0);
          onChanged(hsv.withSaturation(s).withValue(v));
        }

        return Semantics(
          label: '饱和度与明度',
          value: _hexOf(hsv.toColor()),
          child: GestureDetector(
            key: panelKey,
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => update(details.localPosition),
            onPanDown: (details) => update(details.localPosition),
            onPanUpdate: (details) => update(details.localPosition),
            child: SizedBox.fromSize(
              size: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(painter: _SaturationValuePainter(hsv: hsv)),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  _SaturationValuePainter({required this.hsv});

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Colors.black],
        ).createShader(rect),
    );

    // 圆点贴边会被 ClipRRect 裁掉一半，位置往里收一个半径。
    final center = Offset(
      (hsv.saturation * size.width).clamp(10.0, size.width - 10),
      ((1 - hsv.value) * size.height).clamp(10.0, size.height - 10),
    );
    canvas.drawCircle(
      center,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      10.2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}

/// 色相条：彩虹渐变 + 可拖动的圆点。
class _HueBar extends StatelessWidget {
  const _HueBar({required this.hue, required this.onChanged});

  final double hue;
  final ValueChanged<double> onChanged;

  static const double _height = 30;

  /// 轨道两端各缩进的半径：圆点拖到端点时不会画到条外。
  static const double _inset = 11;

  static const Key barKey = Key('theme-color-hue-bar');

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, _height);
        void update(Offset local) {
          final track = (size.width - _inset * 2).clamp(1.0, double.infinity);
          final next = ((local.dx - _inset) / track * 360).clamp(0.0, 359.99);
          onChanged(next);
        }

        return Semantics(
          label: '色相',
          value: '${hue.round()}',
          child: GestureDetector(
            key: barKey,
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => update(details.localPosition),
            onPanDown: (details) => update(details.localPosition),
            onPanUpdate: (details) => update(details.localPosition),
            child: SizedBox.fromSize(
              size: size,
              child: CustomPaint(
                painter: _HuePainter(hue: hue, inset: _inset),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter({required this.hue, required this.inset});

  final double hue;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Rect.fromLTWH(
      inset,
      size.height / 2 - 7,
      size.width - inset * 2,
      14,
    );
    final rrect = RRect.fromRectAndRadius(track, const Radius.circular(7));
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var step = 0; step <= 360; step += 30)
              HSVColor.fromAHSV(1, step.toDouble() % 360, 1, 1).toColor(),
          ],
        ).createShader(track),
    );

    final center = Offset(
      inset + (hue / 360).clamp(0.0, 1.0) * track.width,
      size.height / 2,
    );
    canvas.drawCircle(center, 11, Paint()..color = const Color(0x33000000));
    canvas.drawCircle(center, 10, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      7.4,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) =>
      oldDelegate.hue != hue || oldDelegate.inset != inset;
}

/// 圆形色块（当前选中色 / 预览用）。
class _ColorChip extends StatelessWidget {
  const _ColorChip({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
      ),
    );
  }
}

/// `#4FC3F7` 这种不带 alpha 的十六进制，方便用户跟设计稿对色。
String _hexOf(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
