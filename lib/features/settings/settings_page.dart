import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/theme/app_theme.dart';
import '../../app/theme/theme_settings.dart';
import '../../core/cache/app_cache.dart';
// 设置页集中放全站偏好，会跨 feature 引用偏好 provider（视频清晰度 / 推荐布局）。
// 偏好本身归功能域所有，但入口统一在设置页，所以这里的跨域 import 是约定的。
import '../cache/download_quality.dart';
import '../reader/reader_settings.dart';
import '../recommend/recommend_layout.dart';
import 'settings_providers.dart';
import 'widgets/dialogue_highlight_preview.dart';
import 'widgets/theme_color_picker.dart';

/// 设置页：主题（主题色 / 深浅色 / 首页推荐布局）+ 存储 + 视频。
///
/// 从「我的」右上角进。这里只放全局偏好与可重建缓存，书架/阅读进度属于用户
/// 数据，不给清理入口（那些在「我的」页里操作）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: ListView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: const [
            _SectionTitle('主题'),
            _ThemeColorCard(),
            SizedBox(height: 12),
            _DialogueHighlightColorCard(),
            SizedBox(height: 12),
            _AppearanceCard(),
            SizedBox(height: 12),
            _FeedLayoutCard(),
            _SectionTitle('存储'),
            _StorageCard(),
            _StorageHint(),
            _SectionTitle('视频'),
            _VideoDownloadQualityCard(),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_contentInset, 20, _contentInset, 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 卡片外边距。
const double _cardMargin = 16;

/// 卡片内容左右内边距。
const double _cardPadding = 16;

/// 设置页统一的左右内容线：卡片内容、区块标题、存储提示都对齐到这里，
/// 避免「主题」比下面的 label 往里缩一截。
const double _contentInset = _cardMargin + _cardPadding;

/// 通用卡片容器：与列表页的 Card 圆角/底色保持一致。
///
/// [padding] 可调：只含一行标题 + 控件的卡片用更紧凑的上下边距，否则
/// 卡片内的小标题上下会空出两块 16pt，显得又高又散。
class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(
      _cardPadding,
      16,
      _cardPadding,
      16,
    ),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _cardMargin),
      child: Card(
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主题色
// ---------------------------------------------------------------------------

/// 「自定义颜色」色块的 key：测试用它点开取色弹层。
const Key themeCustomColorKey = Key('theme-color-custom');

class _ThemeColorCard extends ConsumerWidget {
  const _ThemeColorCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final controller = ref.read(themeSeedProvider.notifier);
    final customSeed = ref.watch(customThemeSeedProvider);
    final customController = ref.read(customThemeSeedProvider.notifier);
    final customSelected = !isPresetColor(seed);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            // 首尾圆点分别贴住内容左右边界，和上下的 label / 开关 / chip 对齐。
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final option in themeColorOptions)
                _PresetDot(
                  option: option,
                  selected: option.color == seed,
                  onTap: () => controller.setSeed(option.color),
                ),
              _ColorDot(
                key: themeCustomColorKey,
                color: customSeed,
                selected: customSelected,
                tooltip: '自定义主题色',
                semanticsLabel: '自定义',
                onTap: () async {
                  final picked = await showThemeColorPicker(
                    context,
                    initial: customSeed,
                  );
                  if (picked == null) return;
                  controller.setSeed(picked);
                  customController.setSeed(picked);
                },
              ),
            ],
          ),
          if (seed != appSeedColor)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: controller.reset,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('恢复默认主题色'),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 对话高亮颜色
// ---------------------------------------------------------------------------

/// 「对话高亮」色块的 key：测试用它点开取色弹层。
const Key dialogueHighlightColorKey = Key('settings-dialogue-highlight-color');

/// 阅读页人物对话荧光笔的颜色。和主题色分开：主题色决定全站配色，对话高亮
/// 只是阅读页的一层标记色，用户可以单独挑一个顺眼的荧光笔颜色。
class _DialogueHighlightColorCard extends ConsumerWidget {
  const _DialogueHighlightColorCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final controller = ref.read(readerSettingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '对话高亮',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '阅读页人物对话的荧光笔颜色',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ColorDot(
            key: dialogueHighlightColorKey,
            color: settings.dialogueHighlightColor,
            tooltip: '自定义对话高亮颜色',
            onTap: () async {
              final picked = await showThemeColorPicker(
                context,
                initial: settings.dialogueHighlightColor,
                title: '自定义对话高亮颜色',
                previewBuilder: (color) =>
                    DialogueHighlightPreview(color: color),
              );
              if (picked == null) return;
              controller.setDialogueHighlightColor(picked);
            },
          ),
        ],
      ),
    );
  }
}

/// 圆形色块：实心显示当前颜色，点开取色；[selected] 时描一圈 onSurface 边。
///
/// 主题卡第 4 个「自定义」圆点与「对话高亮」色块共用（两者只差选中态和
/// 语义文案，视觉必须一致，不要再各写一份）。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.semanticsLabel,
  });

  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  /// 当前颜色是否正在生效（描选中边）。
  final bool selected;

  /// 读屏文案；null = 用 [tooltip]。主题卡的自定义圆点用「自定义」而不是
  /// 完整 tooltip，避免读屏把「自定义主题色」和预设色混在一起播报。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.light
        ? Colors.black54
        : Colors.white70;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: semanticsLabel ?? tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 30,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(color: scheme.onSurface, width: 2)
                  : null,
            ),
            child: Icon(Icons.palette_outlined, size: 17, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// 预设色圆点。选中时外圈用 onSurface 描一圈 + 打勾，避免浅色格子看不见。
class _PresetDot extends StatelessWidget {
  const _PresetDot({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ThemeColorOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 勾的颜色按背景亮暗选：早期用亮度阈值 0.55，天蓝/草绿这类中间色会配上
    // 对比度不足的白勾。estimateBrightnessForColor 是 Material 自己的判定。
    final checkColor =
        ThemeData.estimateBrightnessForColor(option.color) == Brightness.light
        ? Colors.black87
        : Colors.white;
    return Tooltip(
      message: option.name,
      child: Semantics(
        button: true,
        selected: selected,
        label: option.name,
        child: InkResponse(
          onTap: onTap,
          radius: 30,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: option.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
            child: selected
                ? Icon(Icons.check_rounded, size: 20, color: checkColor)
                : null,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 深浅色模式
// ---------------------------------------------------------------------------

/// 跟随系统 + 手动深色开关。
///
/// 两个开关都保持可点：开着「跟随系统」时直接点「深色模式」会退出跟随、
/// 固定成手动模式，比把开关置灰更符合直觉。
class _AppearanceCard extends ConsumerWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final controller = ref.read(themeModeProvider.notifier);
    final platformDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final following = mode == ThemeMode.system;
    final dark = following ? platformDark : mode == ThemeMode.dark;
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        children: [
          // 跟随系统时深色由系统决定，这一项没有意义，直接收起。
          if (!following) ...[
            _SwitchRow(
              title: '深色模式',
              subtitle: '关闭后固定使用浅色外观',
              value: dark,
              onChanged: (value) =>
                  controller.setMode(value ? ThemeMode.dark : ThemeMode.light),
            ),
            Divider(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: 0.5),
            ),
          ],
          _SwitchRow(
            title: '跟随系统',
            subtitle: '深色 / 浅色由系统外观决定',
            value: following,
            onChanged: (value) => controller.setMode(
              value
                  ? ThemeMode.system
                  : (platformDark ? ThemeMode.dark : ThemeMode.light),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 首页推荐布局
// ---------------------------------------------------------------------------

/// 每个布局选项的 key：测试直接点，不依赖文案。
///
/// 用枚举名生成而不是三元表达式：以后加第三个选项时不会两个 chip 拿到同一个
/// key（同一 children 列表里重复 key 会在运行期直接抛错）。
Key recommendLayoutOptionKey(RecommendLayout layout) =>
    ValueKey('recommend-layout-${layout.name}');

const Key recommendLayoutTwoKey = ValueKey('recommend-layout-two');
const Key recommendLayoutThreeKey = ValueKey('recommend-layout-three');

/// 首页推荐布局：双列 / 三列瀑布流。
///
/// 与「离线下载清晰度」同一套控件（小标题 + ChoiceChip），标题和选项收在
/// 同一行；不再额外写「封面更大 / 一屏更多」的说明文案。
/// 默认双列，改完立即生效（推荐页 watch 同一个 provider）。
class _FeedLayoutCard extends ConsumerWidget {
  const _FeedLayoutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final layout = ref.watch(recommendLayoutProvider);
    final controller = ref.read(recommendLayoutProvider.notifier);
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '首页推荐布局',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final option in RecommendLayout.values)
                  ChoiceChip(
                    key: recommendLayoutOptionKey(option),
                    label: Text(option.label),
                    selected: option == layout,
                    onSelected: (_) => controller.setLayout(option),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 视频
// ---------------------------------------------------------------------------

/// 离线整剧下载的清晰度上限（默认 720P）。
///
/// 只影响「下一部开始下载」的剧：已下完的内容不自动重下，需要用户删掉重新
/// 缓存；在线播放不受这里影响（默认档由内核选流，后续清晰度面板再开）。
class _VideoDownloadQualityCard extends ConsumerWidget {
  const _VideoDownloadQualityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quality = ref.watch(videoDownloadQualityProvider);
    // 这张卡只有「小标题 + 一排 chip」：上下用 12pt，去掉说明文字，
    // 避免小标题上下各空一块 16pt 显得又高又散。
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '离线下载清晰度',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in VideoDownloadQuality.values)
                ChoiceChip(
                  label: Text(option.label),
                  selected: option == quality,
                  onSelected: (_) => ref
                      .read(videoDownloadQualityProvider.notifier)
                      .setQuality(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 存储
// ---------------------------------------------------------------------------

class _StorageCard extends ConsumerStatefulWidget {
  const _StorageCard();

  @override
  ConsumerState<_StorageCard> createState() => _StorageCardState();
}

class _StorageCardState extends ConsumerState<_StorageCard> {
  bool _clearing = false;

  /// 确认框还开着时再点按钮不能叠出第二个框（两个都点确定会并发清理）。
  bool _confirming = false;

  Future<void> _clear(CacheUsage usage) async {
    if (_clearing || _confirming) return;
    _confirming = true;
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清理缓存？'),
          content: Text(
            '将删除视频、封面、章节等缓存共 ${formatBytes(usage.total)}，'
            '需要时会自动重新下载。书架与阅读进度不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清理'),
            ),
          ],
        ),
      );
    } finally {
      _confirming = false;
    }
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      final freed = await ref.read(appCacheProvider).clear();
      if (!mounted) return;
      ref.invalidate(cacheUsageProvider);
      showAppSnackBar(
        context,
        freed > 0 ? '已清理 ${formatBytes(freed)} 缓存' : '没有可清理的缓存',
      );
    } catch (error) {
      // 缓存统计/删除碰到文件系统或 path_provider 异常时不能让按钮永远停在
      // 「清理中…」：兜底复位并提示，用户还能再试一次。
      debugPrint('[settings] clear cache failed: $error');
      if (!mounted) return;
      showAppSnackBar(context, '清理失败，请重试');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usageAsync = ref.watch(cacheUsageProvider);
    return _Card(
      child: usageAsync.when(
        loading: () => Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              '正在统计缓存占用…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        error: (error, _) => Row(
          children: [
            Expanded(
              child: Text(
                '缓存占用统计失败',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(cacheUsageProvider),
              child: const Text('重试'),
            ),
          ],
        ),
        data: (usage) => _buildUsage(context, usage),
      ),
    );
  }

  Widget _buildUsage(BuildContext context, CacheUsage usage) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UsageRow(
          icon: Icons.smart_display_outlined,
          label: '视频缓存',
          bytes: usage.video,
        ),
        _UsageRow(
          icon: Icons.image_outlined,
          label: '封面缓存',
          bytes: usage.image,
        ),
        _UsageRow(
          icon: Icons.article_outlined,
          label: '章节缓存',
          bytes: usage.chapter,
        ),
        if (usage.legacyLog > 0)
          _UsageRow(
            icon: Icons.description_outlined,
            label: '遗留日志',
            bytes: usage.legacyLog,
          ),
        const SizedBox(height: 6),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                '共 ${formatBytes(usage.total)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: usage.isEmpty || _clearing
                  ? null
                  : () => _clear(usage),
              icon: _clearing
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(_clearing ? '清理中…' : '清理缓存'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            ),
          ],
        ),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.icon,
    required this.label,
    required this.bytes,
  });

  final IconData icon;
  final String label;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 19, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            formatBytes(bytes),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageHint extends StatelessWidget {
  const _StorageHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
      child: Text(
        '离线缓存不在此列，请到「我的 → 缓存」页清理。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }
}
