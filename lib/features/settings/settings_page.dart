import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_version.dart';
import '../../app/router.dart';
import '../../app/theme/app_font_weight.dart';
import '../../app/theme/app_theme.dart';
import '../../app/widgets/app_section_header.dart';
import '../../app/widgets/color_swatch_dot.dart';
import '../../app/widgets/setting_switch_row.dart';
import '../../app/theme/theme_settings.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../core/cache/app_cache.dart';
// 设置页集中放全站偏好，会跨 feature 引用偏好 provider（视频清晰度 / 推荐布局）。
// 偏好本身归功能域所有，但入口统一在设置页，所以这里的跨域 import 是约定的。
import '../cache/download_quality.dart';
import '../reader/reader_settings.dart';
import '../sync/widgets/webdav_sync_card.dart';
import '../recommend/recommend_layout.dart';
import 'settings_providers.dart';
import 'widgets/dialogue_highlight_preview.dart';
import 'widgets/theme_color_picker.dart';

/// 设置页：主题（主题色 / 深浅色 / 推荐流布局 / 全局字重 / 对话高亮）+ 存储（占用清理 + 缓存质量）+ 同步（WebDAV）。
///
/// 从「我的」右上角进。这里只放全局偏好与可重建缓存，书架/阅读进度属于用户
/// 数据，不给清理入口（那些在「我的」页里操作）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 底部安全区当作列表自己的留白，而不是把 ListView 裁在安全区上方：
    // 后者滚到一半时，最后一行会正好被那条黑色安全区「切一半」，看起来像
    // 有个固定底栏盖住设置项（真机反馈「运行日志被盖住一半」）。
    // 这也是推荐 / 搜索 / 我的页的统一做法：内容铺到屏幕底，末行靠 padding
    // 躲开 Home 指示条。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.only(bottom: 28 + bottomInset),
          children: [
            const AppSectionHeader(
              title: '主题',
              padding: EdgeInsets.fromLTRB(
                _contentInset,
                20,
                _contentInset,
                10,
              ),
            ),
            // 整个主题区块共用一张卡：这些偏好都互相独立，拆成多张卡反而
            // 把竖屏切成一截一截；靠行间留白分组就够了，不画分割线。
            const _ThemeCard(),
            const AppSectionHeader(
              title: '同步',
              padding: EdgeInsets.fromLTRB(
                _contentInset,
                20,
                _contentInset,
                10,
              ),
            ),
            const WebDavSyncCard(),
            const AppSectionHeader(
              title: '存储',
              padding: EdgeInsets.fromLTRB(
                _contentInset,
                20,
                _contentInset,
                10,
              ),
            ),
            // 明细 + 清理共用一张卡（与主题区块一致，不画分割线）；缓存质量
            // 是独立偏好，单独一张卡。
            const _StorageSection(),
            const SizedBox(height: 12),
            const _VideoDownloadQualityCard(),
            const AppSectionHeader(
              title: '诊断',
              padding: EdgeInsets.fromLTRB(
                _contentInset,
                20,
                _contentInset,
                10,
              ),
            ),
            const _DiagnosticsCard(),
            const _AppVersionFooter(),
          ],
        ),
      ),
    );
  }
}

/// 设置页里几个按钮组（推荐流布局 / 全局字重 / 缓存质量）共用的外观。
///
/// 不要 M3 默认的描边：一圈外框加段间竖线在卡片上很吵，选中态靠底色已经
/// 够清楚；去掉后整组是一条浅色底轨 + 一个实心选中段。段的左右内边距也收
/// 到 8（默认 12），四档清晰度才放得进同一行、不换行。
ButtonStyle _segmentedStyle(ThemeData theme) {
  final scheme = theme.colorScheme;
  return SegmentedButton.styleFrom(
    side: BorderSide.none,
    backgroundColor: scheme.onSurface.withValues(alpha: 0.05),
    foregroundColor: scheme.onSurfaceVariant,
    selectedBackgroundColor: scheme.secondaryContainer,
    selectedForegroundColor: scheme.onSecondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
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
    this.clipBehavior = Clip.none,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 整卡可点的入口要裁掉水波纹，否则圆角外会看到方角高亮。
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _cardMargin),
      child: Card(
        clipBehavior: clipBehavior,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 主题区块：所有外观偏好共用一张卡，卡内不画分割线。
///
/// 顺序按「一眼就能定」排：主题色 → 深浅色 → 推荐流布局 → 全局字重（仅
/// Android）→ 对话高亮（阅读页局部装饰，放最后）。每行自己带上下 padding，
/// 卡片只保留 6pt 的外边距，行间留白就是唯一的分组手段。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context) {
    // 全局字重只有 Android 有；iOS 直接不建这一行，卡内不留空位。
    final showFontWeight = Theme.of(context).platform == TargetPlatform.android;
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ThemeColorRow(),
          const _AppearanceRows(),
          const _FeedLayoutRow(),
          if (showFontWeight) const _GlobalFontWeightRow(),
          const _DialogueHighlightRow(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 主题色
// ---------------------------------------------------------------------------

/// 「自定义颜色」色块的 key：测试用它点开取色弹层。
const Key themeCustomColorKey = Key('theme-color-custom');

class _ThemeColorRow extends ConsumerWidget {
  const _ThemeColorRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(themeSeedProvider);
    final controller = ref.read(themeSeedProvider.notifier);
    final customSeed = ref.watch(customThemeSeedProvider);
    final customController = ref.read(customThemeSeedProvider.notifier);
    final customSelected = !isPresetColor(seed);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            // 首尾圆点分别贴住内容左右边界，和上下的 label / 开关 / chip 对齐。
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final option in themeColorOptions)
                ColorSwatchDot(
                  color: option.color,
                  tooltip: option.name,
                  selected: option.color == seed,
                  onTap: () => controller.setSeed(option.color),
                ),
              ColorSwatchDot(
                key: themeCustomColorKey,
                color: customSeed,
                selected: customSelected,
                showCheck: false,
                icon: Icons.palette_outlined,
                tooltip: '自定义主题色',
                semanticLabel: '自定义',
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
// 对话高亮（样式 + 颜色）
// ---------------------------------------------------------------------------

/// 「对话高亮」色块的 key：测试用它点开取色弹层。
const Key dialogueHighlightColorKey = Key('settings-dialogue-highlight-color');

/// 「对话高亮」样式按钮组的 key：测试用它点选荧光笔 / 下划线 / 波浪线。
const Key dialogueHighlightStyleKey = Key('settings-dialogue-highlight-style');

/// 阅读页人物对话荧光笔的颜色。和主题色分开：主题色决定全站配色，对话高亮
/// 只是阅读页的一层标记色，用户可以单独挑一个顺眼的荧光笔颜色。
class _DialogueHighlightRow extends ConsumerWidget {
  const _DialogueHighlightRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final controller = ref.read(readerSettingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 样式和颜色都收进右边圆点打开的弹层里：圆点亮的是当前颜色，点开先挑
      // 画法再挑颜色，预览跟着两者一起变。
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '对话高亮',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: context.appWeight(FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '样式与颜色，点右侧圆点调整',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ColorSwatchDot(
            key: dialogueHighlightColorKey,
            color: settings.dialogueHighlightColor,
            showCheck: false,
            icon: Icons.palette_outlined,
            tooltip: '自定义对话高亮样式与颜色',
            onTap: () async {
              final picked = await showThemeColorPicker(
                context,
                initial: settings.dialogueHighlightColor,
                title: '对话高亮样式与颜色',
                // 画法直接写阅读设置（弹层里点完立刻生效）；颜色等「确定」。
                leading: const _DialogueHighlightStylePicker(),
                previewBuilder: (color) =>
                    _DialogueHighlightPreviewSlot(color: color),
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

/// 取色弹层里的「标记样式」按钮组。
///
/// 自己 watch 阅读设置：点一下立即写入并刷新弹层预览，不用退出重开。
/// 取消弹层只回滚颜色，样式已经生效（和开关类设置的手感一致）。
class _DialogueHighlightStylePicker extends ConsumerWidget {
  const _DialogueHighlightStylePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(readerSettingsProvider).dialogueHighlightStyle;
    return SegmentedButton<DialogueHighlightStyle>(
      key: dialogueHighlightStyleKey,
      style: _segmentedStyle(Theme.of(context)),
      segments: [
        for (final style in DialogueHighlightStyle.values)
          ButtonSegment(value: style, label: Text(style.label)),
      ],
      selected: {style},
      showSelectedIcon: false,
      onSelectionChanged: (selected) => ref
          .read(readerSettingsProvider.notifier)
          .setDialogueHighlightStyle(selected.single),
    );
  }
}

/// 取色弹层里的预览槽：颜色由弹层按帧传进来，样式自己 watch。
///
/// 拆成 ConsumerWidget 是为了「只切样式」时也能刷新预览——弹层只在拖动取色时
/// 重建，切样式不会让它重建。
class _DialogueHighlightPreviewSlot extends ConsumerWidget {
  const _DialogueHighlightPreviewSlot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DialogueHighlightPreview(
      color: color,
      style: ref.watch(readerSettingsProvider).dialogueHighlightStyle,
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
class _AppearanceRows extends ConsumerWidget {
  const _AppearanceRows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final controller = ref.read(themeModeProvider.notifier);
    final platformDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final following = mode == ThemeMode.system;
    final dark = following ? platformDark : mode == ThemeMode.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          // 跟随系统时深色由系统决定，这一项没有意义，直接收起。
          if (!following)
            SettingSwitchRow(
              padding: const EdgeInsets.symmetric(vertical: 4),
              title: '深色模式',
              subtitle: '关闭后固定使用浅色外观',
              value: dark,
              onChanged: (value) =>
                  controller.setMode(value ? ThemeMode.dark : ThemeMode.light),
            ),
          SettingSwitchRow(
            padding: const EdgeInsets.symmetric(vertical: 4),
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

// ---------------------------------------------------------------------------
// 全局字重（仅 Android）
// ---------------------------------------------------------------------------

/// 全局字重按钮组；测试用它点档位和断言。
const Key globalFontWeightKey = Key('settings-global-font-weight');

/// 每个字重档位的 key：测试直接点，不依赖文案。
Key globalFontWeightOptionKey(int value) =>
    ValueKey('settings-global-font-weight-$value');

/// 全局字重：只有 Android 显示，iOS 保持现在的写死字重。
///
/// 只开放 300 / 400 / 500 三档（见 [appFontWeightSteps]）：两头的极细/极粗
/// 在正文里可读性明显变差，不值当。三档互斥、又要一眼看出当前值，所以用
/// 按钮组（与「推荐流布局」同一种控件）而不是滑块。
class _GlobalFontWeightRow extends ConsumerWidget {
  const _GlobalFontWeightRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final weight = appFontWeightFromValue(
      ref.watch(appFontWeightProvider).value,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '全局字重',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: context.appWeight(FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<int>(
            key: globalFontWeightKey,
            style: _segmentedStyle(theme),
            segments: [
              for (final step in appFontWeightSteps)
                ButtonSegment(
                  value: step,
                  label: Text('$step', key: globalFontWeightOptionKey(step)),
                ),
            ],
            selected: {weight.value},
            // 段里只有三位数字，打勾会把控件撑宽；选中态靠底色区分。
            showSelectedIcon: false,
            onSelectionChanged: (selected) => ref
                .read(appFontWeightProvider.notifier)
                .setFontWeight(appFontWeightFromValue(selected.single)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 推荐流布局
// ---------------------------------------------------------------------------

/// 每个布局选项的 key：测试直接点，不依赖文案。
///
/// 用枚举名生成而不是三元表达式：以后加第三个选项时不会两个 chip 拿到同一个
/// key（同一 children 列表里重复 key 会在运行期直接抛错）。
Key recommendLayoutOptionKey(RecommendLayout layout) =>
    ValueKey('recommend-layout-${layout.name}');

const Key recommendLayoutTwoKey = ValueKey('recommend-layout-two');
const Key recommendLayoutThreeKey = ValueKey('recommend-layout-three');

/// 推荐流布局：双列 / 三列瀑布流。
///
/// 与「缓存质量」同一种控件（M3 SegmentedButton，按钮组）：两个互斥选项
/// 就是按钮组最直接的表达，比一排独立 chip 更省地方、选中态也连成一体。
/// 标题和选项收在同一行，不写「封面更大 / 一屏更多」这类说明文案；标题自身
/// 超宽时省略，不挤压按钮组。
/// 默认双列，改完立即生效（推荐页 watch 同一个 provider）。
class _FeedLayoutRow extends ConsumerWidget {
  const _FeedLayoutRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final layout = ref.watch(recommendLayoutProvider);
    final controller = ref.read(recommendLayoutProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 标题占剩余宽度（长标题省略），按钮组按内容宽贴右端：就是
          // CSS `justify-content: space-between` 的效果。
          Expanded(
            child: Text(
              '推荐流布局',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: context.appWeight(FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<RecommendLayout>(
            style: _segmentedStyle(theme),
            segments: [
              for (final option in RecommendLayout.values)
                ButtonSegment(
                  value: option,
                  label: Text(
                    option.label,
                    key: recommendLayoutOptionKey(option),
                  ),
                ),
            ],
            selected: {layout},
            // 段里只有两个字，打勾会把控件撑宽一倍；选中态靠底色区分。
            showSelectedIcon: false,
            onSelectionChanged: (selected) =>
                controller.setLayout(selected.single),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 存储：缓存质量
// ---------------------------------------------------------------------------

/// 离线整剧下载的清晰度上限（默认 720P）。
///
/// 只影响「下一部开始下载」的剧：已下完的内容不自动重下，需要用户删掉重新
/// 缓存；在线播放不受这里影响（默认档由内核选流，后续清晰度面板再开）。
/// 标题精简成「缓存质量」：区块标题已经是「存储」，这里不必再重复「离线」；
/// 它管的是「主动下载整本/整剧时存多大」，不是在线播放清晰度。
class _VideoDownloadQualityCard extends ConsumerWidget {
  const _VideoDownloadQualityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quality = ref.watch(videoDownloadQualityProvider);
    return _Card(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      // 和「推荐流布局」同一套排版：标题左、四档按钮组右，两端对齐（不再
      // 标题独占一行、按钮另起一行）。
      child: Row(
        children: [
          Expanded(
            child: Text(
              '缓存质量',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: context.appWeight(FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<VideoDownloadQuality>(
            style: _segmentedStyle(theme),
            segments: [
              for (final option in VideoDownloadQuality.values)
                ButtonSegment(value: option, label: Text(option.label)),
            ],
            selected: {quality},
            showSelectedIcon: false,
            onSelectionChanged: (selected) => ref
                .read(videoDownloadQualityProvider.notifier)
                .setQuality(selected.single),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 存储
// ---------------------------------------------------------------------------

/// 清理卡右侧的清理入口：测试用它点，不依赖图标/文案。
const Key clearCacheButtonKey = Key('settings-clear-cache');

/// 存储区块：占用明细一张卡，清理单独一张卡。
///
/// 拆两张卡是为了把「纯信息」和「破坏性动作」分开：明细不再画行间分割线、
/// 也不带每行图标（三行短文本本来就是一列数据，图标只会把行高撑散），
/// 清理那张卡里放「共 x MB」+ 适用范围说明 + 右侧图标按钮。
class _StorageSection extends ConsumerStatefulWidget {
  const _StorageSection();

  @override
  ConsumerState<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<_StorageSection> {
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
    final usage = usageAsync.value;
    return _Card(
      // 明细、清理、缓存质量都在一张卡里：行间靠留白分组，不画分割线。
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          usageAsync.when(
            loading: () => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
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
            data: (usage) => Column(
              children: [
                _UsageRow(label: '视频缓存', bytes: usage.video),
                _UsageRow(label: '封面缓存', bytes: usage.image),
                _UsageRow(label: '章节缓存', bytes: usage.chapter),
                if (usage.legacyLog > 0)
                  _UsageRow(label: '遗留日志', bytes: usage.legacyLog),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _buildClearRow(
            theme,
            usage == null ? null : '共 ${formatBytes(usage.total)}',
            // 只有真正拿到统计、且还有东西可清时才允许点；loading / 失败
            // 期间按钮置灰，避免对着「共 —」弹确认框。
            onClear: usage == null || usage.isEmpty || _clearing
                ? null
                : () => _clear(usage),
          ),
        ],
      ),
    );
  }

  Widget _buildClearRow(
    ThemeData theme,
    String? total, {
    required VoidCallback? onClear,
  }) {
    final scheme = theme.colorScheme;
    return Row(
      // 整行按中线对齐：按钮的触控区比文字高，若也按底边对齐，文字会被
      // 压在卡片底部、上方空出一截（截图里像「卡片高度不对」）。
      children: [
        Expanded(
          child: Row(
            // 「共 x MB」与副标题字号不同，这两段之间按底边对齐。
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                total ?? '共 —',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: context.appWeight(FontWeight.w600),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '不包括主动下载',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: clearCacheButtonKey,
          tooltip: '清理缓存',
          onPressed: onClear,
          icon: _clearing
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cleaning_services_outlined, size: 18),
          color: scheme.onSurfaceVariant,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          visualDensity: VisualDensity.compact,
          // 不 shrinkWrap 的话 M3 会把触控区撑到 40，卡片跟着变高。
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.label, required this.bytes});

  final String label;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
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

// ---------------------------------------------------------------------------
// 诊断
// ---------------------------------------------------------------------------

/// 运行日志入口的 key：测试用它点进日志页。
const Key diagnosticsLogEntryKey = Key('settings-diagnostics-log');

/// 诊断：运行日志入口。
///
/// 放在设置最底部：排障是低频动作，别把主流程（主题/同步/存储）往后挤。
class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: diagnosticsLogEntryKey,
        onTap: () => context.pushAppRoute(const AppLogRoute()),
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cardPadding),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '运行日志',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: context.appWeight(FontWeight.w600),
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 版本脚注：设置页最底部，灰色、居中，显示当前安装包的版本号与构建号。
///
/// 版本来自原生包元数据（见 [appVersionProvider]）；测试/桌面环境没有原生
/// 通道时返回 null，这里不占位，避免 golden 里多出一行"假版本"。
class _AppVersionFooter extends ConsumerWidget {
  const _AppVersionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    if (version == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      // 上间距把版本脚注和「视频」区块分开；下间距交给 ListView 的 bottom padding。
      padding: const EdgeInsets.fromLTRB(_contentInset, 24, _contentInset, 0),
      child: Center(
        child: Text(
          '$appFlavorLabel ${version.label}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
