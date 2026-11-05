import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/theme_settings.dart';
import '../../core/cache/app_cache.dart';
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
            _SectionTitle('主题色'),
            _ThemeColorCard(),
            _SectionTitle('存储'),
            _StorageCard(),
            _StorageHint(),
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
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主题色
// ---------------------------------------------------------------------------

class _ThemeColorCard extends ConsumerWidget {
  const _ThemeColorCard();

  /// 一行四个：8 个预设正好两行，不会出现「6 + 2」这种歪掉的收尾。
  static const _perRow = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final controller = ref.read(themeSeedProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < themeColorOptions.length; row += _perRow) ...[
            if (row > 0) const SizedBox(height: 12),
            Row(
              children: [
                for (var column = 0; column < _perRow; column++)
                  Expanded(
                    child: Center(
                      child: row + column < themeColorOptions.length
                          ? _PresetDot(
                              option: themeColorOptions[row + column],
                              selected:
                                  themeColorOptions[row + column].color == seed,
                              onTap: () => controller.setSeed(
                                themeColorOptions[row + column].color,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              final picked = await showThemeColorPicker(context, initial: seed);
              if (picked == null) return;
              controller.setSeed(picked);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: seed,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: scheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '自定义颜色',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    themeColorName(seed),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
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
        '清理只删除可重新下载的缓存（视频、封面、章节、遗留日志），书架与阅读进度不会动。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }
}
