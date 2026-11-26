import 'package:flutter/material.dart';
// 读屏「上移 / 下移」动作：CustomSemanticsAction 不在 material 的导出里。
import 'package:flutter/semantics.dart';
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
import '../mine/mine_section_order.dart';
import '../reader/reader_settings.dart';
import '../sync/widgets/webdav_sync_card.dart';
import '../recommend/recommend_layout.dart';
import 'settings_providers.dart';
import 'widgets/dialogue_highlight_preview.dart';
import 'widgets/theme_color_picker.dart';

/// 设置页：外观（主题色 / 深浅色 / 推荐流布局 / 我的页模块顺序 / 全局字重 /
/// 对话高亮）+ 存储（占用清理 + 缓存质量）+ 同步（WebDAV）。
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
              title: '外观',
              padding: EdgeInsets.fromLTRB(
                _contentInset,
                20,
                _contentInset,
                10,
              ),
            ),
            // 外观区块：整站观感共用一张卡（卡内不画分割线）；「对话高亮」只
            // 影响阅读页正文，单独一张卡跟在后面，但仍然属于「外观」区块。
            const _ThemeCard(),
            const SizedBox(height: 12),
            const _DialogueHighlightCard(),
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

/// 外观区块的主卡：整站观感偏好共用一张卡，卡内不画分割线。
///
/// 顺序按「一眼就能定」排：主题色 → 深浅色 → 推荐流布局 → 我的页模块（拖动
/// 排序）→ 全局字重（仅 Android）。每行自己带上下 padding，卡片只保留 6pt
/// 的外边距，行间留白就是唯一的分组手段。
///
/// 「对话高亮」只影响阅读页正文，不在这里：它是同一区块里的第二张卡
/// （见 [_DialogueHighlightCard]）。
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
          const _MineSectionOrderRow(),
          if (showFontWeight) const _GlobalFontWeightRow(),
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

/// 主题色圆点之间的间距。
///
/// 圆点自身 44（保证点击热区），四颗 + 三个间隙 = 212；右侧对齐后左边留给
/// 「主题色」文案，最窄的 375pt 屏（内容宽 311）也放得下。
const double _themeColorDotGap = 12;

class _ThemeColorRow extends ConsumerWidget {
  const _ThemeColorRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final seed = ref.watch(themeSeedProvider);
    final controller = ref.read(themeSeedProvider.notifier);
    final customSeed = ref.watch(customThemeSeedProvider);
    final customController = ref.read(customThemeSeedProvider.notifier);
    final customSelected = !isPresetColor(seed);
    final dots = <Widget>[
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
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 文案左、圆点整组右对齐：和卡里其它「标题 + 右侧控件」的行同一套
          // 版式。四颗圆点铺满整行时看不出这是一项设置。
          Row(
            children: [
              Expanded(
                child: Text(
                  '主题色',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: context.appWeight(FontWeight.w600),
                  ),
                ),
              ),
              for (var i = 0; i < dots.length; i++) ...[
                if (i > 0) const SizedBox(width: _themeColorDotGap),
                dots[i],
              ],
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

/// 对话高亮：只影响阅读页正文里的标记色，和整站外观不是一类设置，单独一张卡。
///
/// 仍属于「外观」区块（区块标题不重复），与上面的外观卡留 12 的间距 ——
/// 和「存储 → 缓存质量」同一套排版。
class _DialogueHighlightCard extends StatelessWidget {
  const _DialogueHighlightCard();

  @override
  Widget build(BuildContext context) => const _Card(
    padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: _DialogueHighlightRow(),
  );
}

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
// 我的页模块（拖动排序）
// ---------------------------------------------------------------------------

/// 「我的页模块」整组的 key：测试用它滚到可见位置。
const Key mineSectionOrderKey = Key('settings-mine-section-order');

/// 「恢复默认」按钮的 key（只在非默认顺序时出现）。
const Key mineSectionResetKey = Key('settings-mine-section-reset');

/// 拖动行的 key（按区块名取，不依赖下标）。
Key mineSectionOrderRowKey(MineSection section) =>
    ValueKey('settings-mine-section-${section.name}');

/// 「我的页模块」：三条可拖动行，直接决定「我的」页三个区块的先后。
///
/// 不单独开一个设置区块：它和「推荐流布局」同属布局偏好，三行也不值得再占
/// 一张卡，所以并进外观卡。拖动即时生效（与开关 / 按钮组一致，没有确定/取消）：
/// 「我的」页 watch 同一个 provider，返回后立刻按新顺序渲染。
///
/// 手柄才起拖（`buildDefaultDragHandles: false`）：设置页整页还要能竖向滚，
/// 整行长按拖动会和页面滚动抢手势。
class _MineSectionOrderRow extends ConsumerWidget {
  const _MineSectionOrderRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final order = ref.watch(mineSectionOrderProvider);
    final controller = ref.read(mineSectionOrderProvider.notifier);
    final isDefault = sameMineSectionOrder(order, defaultMineSectionOrder);

    void move(int from, int to) =>
        controller.setOrder(reorderMineSections(order, from, to));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '我的页模块',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: context.appWeight(FontWeight.w600),
                  ),
                ),
              ),
              if (!isDefault)
                TextButton(
                  key: mineSectionResetKey,
                  onPressed: controller.reset,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('恢复默认'),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '拖动右侧手柄调整先后，没有内容的区块会自动隐藏',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          ReorderableListView.builder(
            key: mineSectionOrderKey,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            padding: EdgeInsets.zero,
            itemCount: order.length,
            // onReorder 在 3.41 之后已废弃（newIndex 要自己减 1）；
            // onReorderItem 直接给「移除后再插入」的目标下标。
            onReorderItem: (oldIndex, newIndex) => controller.setOrder(
              reorderMineSections(order, oldIndex, newIndex),
            ),
            proxyDecorator: (child, index, animation) => AnimatedBuilder(
              animation: animation,
              // 拖动中的行抬起来：不抬的话整行跟着手指走、又没有层级变化，
              // 看起来像在滚动而不是在排序。
              builder: (context, _) => Material(
                color: scheme.surfaceContainerHigh,
                elevation: 4 * Curves.easeOut.transform(animation.value),
                borderRadius: BorderRadius.circular(10),
                shadowColor: scheme.shadow.withValues(alpha: 0.3),
                child: child,
              ),
            ),
            itemBuilder: (context, index) {
              final section = order[index];
              return _MineSectionOrderTile(
                key: ValueKey(section),
                section: section,
                index: index,
                total: order.length,
                onMoveUp: index == 0 ? null : () => move(index, index - 1),
                onMoveDown: index == order.length - 1
                    ? null
                    : () => move(index, index + 1),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 拖动行：图标 + 区块名 + 右侧手柄。
///
/// 行本身不可点（只有手柄起拖）：点一下没有任何结果的「假可点」比不给手势更
/// 让人困惑。行尾手柄带 Tooltip，读屏会念「拖动调整…的位置」。
class _MineSectionOrderTile extends StatelessWidget {
  const _MineSectionOrderTile({
    super.key,
    required this.section,
    required this.index,
    required this.total,
    this.onMoveUp,
    this.onMoveDown,
  });

  final MineSection section;
  final int index;

  /// 总行数：只用于读屏语义「第 N 项 / 共 M 项」。
  final int total;

  /// 读屏「上移 / 下移」动作用的回调；首尾行对应方向为 null。
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final up = onMoveUp;
    final down = onMoveDown;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        container: true,
        // 整行当一个节点播报：子节点的文字 / 手柄不再单独抢焦点，
        // 排序用下面两个自定义动作，读屏用户不用长按拖动。
        excludeSemantics: true,
        label: '${section.label}，第 ${index + 1} 项，共 $total 项，可拖动排序',
        customSemanticsActions: {
          const CustomSemanticsAction(label: '上移'): ?up,
          const CustomSemanticsAction(label: '下移'): ?down,
        },
        child: Container(
          key: mineSectionOrderRowKey(section),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(section.icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Tooltip(
                  message: '拖动调整「${section.label}」的位置',
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.drag_handle_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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

/// 每个缓存行尾清理按钮的 key：测试直接点，不依赖图标/文案。
Key clearCacheButtonKey(CacheKind kind) =>
    ValueKey('settings-clear-cache-${kind.name}');

/// [CacheKind] 在设置页的显示文案。
extension on CacheKind {
  String get label => switch (this) {
    CacheKind.video => '视频缓存',
    CacheKind.image => '封面缓存',
    CacheKind.chapter => '章节缓存',
    CacheKind.legacyLog => '遗留日志',
  };
}

/// 存储区块：每一类缓存一行，行尾一个清理图标，点谁只清谁。
///
/// 不再有「共 x MB」总计和一次性清空按钮：用户反馈那样只能整块清，想只清
/// 视频 / 封面 / 章节时没有入口。三行明细不带行首图标（图标会把行高撑散），
/// 行尾的清理按钮才是有意义的动作。
///
/// 「遗留日志」只在真有文件时出现；它不是自动缓存，但删掉总清入口后必须给它
/// 留一个单独的清理入口，否则这份旧文件永远清不掉。
class _StorageSection extends ConsumerStatefulWidget {
  const _StorageSection();

  @override
  ConsumerState<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<_StorageSection> {
  /// 正在清理的缓存种类；null = 空闲。
  ///
  /// 清理期间所有行尾按钮都禁用：同一时刻只允许一个清理动作，避免两行同时
  /// 删文件、统计与刷新互相打架。
  CacheKind? _clearing;

  Future<void> _clear(CacheKind kind) async {
    if (_clearing != null) return;
    setState(() => _clearing = kind);
    try {
      final freed = await ref.read(appCacheProvider).clearKind(kind);
      if (!mounted) return;
      ref.invalidate(cacheUsageProvider);
      showAppSnackBar(
        context,
        freed > 0
            ? '已清理${kind.label} ${formatBytes(freed)}'
            : '${kind.label}没有可清理的内容',
      );
    } catch (error) {
      // 缓存统计/删除碰到文件系统或 path_provider 异常时不能让按钮永远停在
      // 「清理中」：兜底复位并提示，用户还能再试一次。
      debugPrint('[settings] clear ${kind.name} failed: $error');
      if (!mounted) return;
      showAppSnackBar(context, '清理${kind.label}失败，请重试');
    } finally {
      if (mounted) setState(() => _clearing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usageAsync = ref.watch(cacheUsageProvider);
    return _Card(
      // 明细都在一张卡里：行间靠留白分组，不画分割线。
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: usageAsync.when(
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
        error: (error, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
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
        ),
        data: (usage) => Column(
          children: [
            _UsageRow(
              kind: CacheKind.video,
              bytes: usage.video,
              clearing: _clearing,
              onClear: () => _clear(CacheKind.video),
            ),
            _UsageRow(
              kind: CacheKind.image,
              bytes: usage.image,
              clearing: _clearing,
              onClear: () => _clear(CacheKind.image),
            ),
            _UsageRow(
              kind: CacheKind.chapter,
              bytes: usage.chapter,
              clearing: _clearing,
              onClear: () => _clear(CacheKind.chapter),
            ),
            if (usage.legacyLog > 0)
              _UsageRow(
                kind: CacheKind.legacyLog,
                bytes: usage.legacyLog,
                clearing: _clearing,
                onClear: () => _clear(CacheKind.legacyLog),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一类缓存的占用行：左侧名称、中间大小、右侧单独的清理按钮。
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.kind,
    required this.bytes,
    required this.clearing,
    required this.onClear,
  });

  final CacheKind kind;
  final int bytes;

  /// 当前正在清理的种类（区别于本条是否正在清）。
  final CacheKind? clearing;

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isClearing = clearing == kind;
    final enabled = bytes > 0 && clearing == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(kind.label, style: theme.textTheme.bodyMedium)),
          Text(
            formatBytes(bytes),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: clearCacheButtonKey(kind),
            tooltip: '清理${kind.label}',
            onPressed: enabled ? onClear : null,
            icon: isClearing
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cleaning_services_outlined, size: 18),
            color: scheme.onSurfaceVariant,
            disabledColor: scheme.onSurfaceVariant.withValues(alpha: 0.38),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            // 不 shrinkWrap 的话 M3 会把触控区撑到 48，卡片跟着变高；
            // 32 是「紧凑但还能点准」的折中，比旧整卡清理按钮更小。
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
