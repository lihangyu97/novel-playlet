import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/theme_settings.dart';
import '../../core/cache/app_cache.dart';
import '../cache/download_quality.dart';
import 'settings_providers.dart';
import 'widgets/theme_color_picker.dart';

/// 设置页：主题色 + 存储。
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
            _AppearanceCard(),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 通用卡片容器：与列表页的 Card 圆角/底色保持一致。
///
/// [padding] 可调：只含一行标题 + 控件的卡片用更紧凑的上下边距，否则
/// 卡片内的小标题上下会空出两块 16pt，显得又高又散。
class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
    final customSelected = !isPresetColor(seed);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final option in themeColorOptions)
                Expanded(
                  child: Center(
                    child: _PresetDot(
                      option: option,
                      selected: option.color == seed,
                      onTap: () => controller.setSeed(option.color),
                    ),
                  ),
                ),
              Expanded(
                child: Center(
                  child: _CustomDot(
                    key: themeCustomColorKey,
                    selected: customSelected,
                    tooltip: '自定义 · ${themeColorName(seed)}',
                    onTap: () async {
                      final picked = await showThemeColorPicker(
                        context,
                        initial: seed,
                      );
                      if (picked == null) return;
                      controller.setSeed(picked);
                    },
                  ),
                ),
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

/// 第四个色块：自定义取色入口。
///
/// 永远显示彩虹渐变 + 调色板图标（不跟随当前 seed），避免和预设色画出两个
/// 一模一样的圆点；当前主题色不是预设色时用选中描边表示「自定义正在生效」。
class _CustomDot extends StatelessWidget {
  const _CustomDot({
    super.key,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: '自定义',
        child: InkResponse(
          onTap: onTap,
          radius: 30,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const SweepGradient(
                colors: [
                  Color(0xFFEF5350),
                  Color(0xFFFFA726),
                  Color(0xFF66BB6A),
                  Color(0xFF4FC3F7),
                  Color(0xFF5C6BC0),
                  Color(0xFFAB47BC),
                  Color(0xFFEF5350),
                ],
              ),
              border: Border.all(
                color: selected ? scheme.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
            child: Center(
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.palette_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            freed > 0 ? '已清理 ${formatBytes(freed)} 缓存' : '没有可清理的缓存',
          ),
        ),
      );
    } catch (error) {
      // 缓存统计/删除碰到文件系统或 path_provider 异常时不能让按钮永远停在
      // 「清理中…」：兜底复位并提示，用户还能再试一次。
      debugPrint('[settings] clear cache failed: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('清理失败，请重试')));
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
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
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
