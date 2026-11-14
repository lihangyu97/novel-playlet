import '../app_snack_bar.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/cache/app_image_cache.dart';
import '../../theme/app_theme.dart';
import '../cover_hero.dart';

/// 详情页左右留白。卡片、目录行、底部操作栏共用，保证竖线对齐。
const double detailGutter = 16;

/// 详情页顶部封面背景。
///
/// 用列表带进来的封面铺满顶部固定高度：自上而下做透明度渐变（顶部
/// opacity 1、底部 0）并轻微模糊，图片经 Hero 从列表卡片飞进来后直接成为
/// 背景。高度只由本组件决定，和下方标题/简介/选集的内容高度无关，所以
/// 详情接口回来、内容变高时背景不会跟着动一下。
class DetailCoverBackdrop extends StatelessWidget {
  const DetailCoverBackdrop({
    super.key,
    required this.cover,
    this.heroTag,
    this.height = 230,
  });

  final String cover;

  /// 封面 Hero tag：列表点进来时由导航参数带下来，null = 不飞入。
  final String? heroTag;

  /// 状态栏以下可见的背景高度。
  final double height;

  /// 背景的固定模糊程度；飞行过程中由 [_coverFlightShuttle] 从 0 渐变到这里。
  static const double blurSigma = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;
    // 230pt 的模糊背景要盖满整屏宽度：按屏宽物理像素的 1.5 倍解码就够
    // （高斯模糊本身会吃掉细节），不必把上游 1080–1440px 的原图整张解成
    // RGBA 再交给 ImageFiltered。1.5 是给 hero 飞行放大时留的余量；内存
    // 请求比磁盘上限（1440）更大时以磁盘为准，Flutter 不会放大，所以高 dpr
    // 大屏上两个数不必完全相等。
    final decodeWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context) *
                1.5)
            .round();
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.primary.withValues(alpha: 0.12),
            scheme.primary.withValues(alpha: 0),
          ],
        ),
      ),
    );

    return SizedBox(
      width: double.infinity,
      height: topInset + height,
      child: ClipRect(
        child: ShaderMask(
          // dstIn：白色渐变只保留图片对应的不透明度。顶部全白 = 完全不透明，
          // 底部全透明 = 完全露出页面底色。
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0x00FFFFFF)],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: cover.isEmpty
              ? fallback
              : ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: CoverHero(
                    tag: heroTag,
                    flightShuttleBuilder: _coverFlightShuttle,
                    child: SizedBox.expand(
                      child: CachedNetworkImage(
                        imageUrl: cover,
                        cacheManager: AppImageCache.manager,
                        fit: BoxFit.cover,
                        memCacheWidth: decodeWidth,
                        // 磁盘也别存原图；1440 已覆盖 Pro Max 的 1.5 倍余量。
                        maxWidthDiskCache: 1440,
                        placeholder: (_, _) => fallback,
                        errorWidget: (_, _, _) => fallback,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 封面 Hero 的飞行过程：从清晰的小圆角卡片逐渐放大、模糊、削圆角，
/// 落位时正好与背景的固定模糊/直角衔接，不会"啪"一下换形。
Widget _coverFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final hero =
      (direction == HeroFlightDirection.push
              ? toHeroContext.widget
              : fromHeroContext.widget)
          as Hero;
  final child = hero.child;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      // push 时动画跑 0→1（卡片 → 背景），pop 时被弹出路由的动画本来就跑
      // 1→0（背景 → 卡片），所以两个方向都用 animation.value 当"背景化"
      // 的进度即可；不要再按方向取反，否则返回时会先变清晰再变模糊。
      final progress = animation.value;
      // 落位目标是列表卡片的封面：卡片是「上圆下方」——上面两角跟着白底卡
      // 的圆角，下面两角和文字区相接所以是直角。飞行中只圆上面两角、下面
      // 两角始终直角；四角一起圆会在 Hero 结束、卡片接管的那一帧出现
      // 「下两角由圆变尖」的闪动（详情背景本身是直角，start 端不受影响）。
      final cornerRadius = AppTheme.mediaCardRadius * (1 - progress);
      return ClipRRect(
        // 飞行中的 shuttle 单独打 key，方便测试断言「进/出详情都有飞行动画」。
        key: const ValueKey('cover-hero-flight'),
        borderRadius: BorderRadius.vertical(top: Radius.circular(cornerRadius)),
        child: ShaderMask(
          // 透明渐变也随飞行进度渐入：起飞时整张图都在，落位时正好和背景
          // 底部的全透明渐变对齐，不会在落地瞬间"啪"地切一下。
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
              Color.lerp(Colors.white, Colors.transparent, progress)!,
            ],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: DetailCoverBackdrop.blurSigma * progress,
              sigmaY: DetailCoverBackdrop.blurSigma * progress,
            ),
            child: child,
          ),
        ),
      );
    },
  );
}

/// 书名/作者/分类·字数/评分等文字区。
///
/// 单独从背景里拆出来，是为了让它在详情接口就绪后再从下方淡入；背景和
/// Hero 落位不依赖这段内容，接口回来时页面不会整体跳一下。
class DetailTitleSection extends StatelessWidget {
  const DetailTitleSection({
    super.key,
    required this.title,
    this.subtitle = '',
    this.extra,
  });

  final String title;

  /// 副标题：小说是「作者 · 状态 · 字数」，短剧是「全 N 集 · 播放量」。
  final String subtitle;

  /// 附加区域：小说放「评分 · 在读 · 更新至」，短剧可为空。
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        detailGutter + 4,
        6,
        detailGutter + 4,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (extra != null) ...[const SizedBox(height: 8), extra!],
        ],
      ),
    );
  }
}

/// 内容就绪后的淡入 + 上移。
///
/// 配合「封面先飞进来当背景、文字信息后出现」的节奏；[delay] 用来让相邻
/// 区块错开出现（标题 → 简介 → 目录/选集），比统一淡入更有层次。
class DetailFadeIn extends StatefulWidget {
  const DetailFadeIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  static const Duration duration = Duration(milliseconds: 420);
  static const double _slideDistance = 28;

  @override
  State<DetailFadeIn> createState() => _DetailFadeInState();
}

class _DetailFadeInState extends State<DetailFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: DetailFadeIn.duration,
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Timer? _delayTimer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      return;
    }
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) {
        final value = _animation.value;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, DetailFadeIn._slideDistance * (1 - value)),
            child: child,
          ),
        );
      },
    );
  }
}

/// 简介 + 标签卡片。简介默认折叠 [collapsedLines] 行，超出才给展开/收起。
class DetailIntroCard extends StatelessWidget {
  const DetailIntroCard({
    super.key,
    required this.intro,
    this.tags = const [],
    this.collapsedLines = 4,
  });

  final String intro;
  final List<String> tags;
  final int collapsedLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = intro.trim();
    return Card(
      margin: const EdgeInsets.fromLTRB(detailGutter, 6, detailGutter, 0),
      child: Padding(
        padding: const EdgeInsets.all(detailGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '简介',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ExpandableIntro(
              text: text.isEmpty ? '暂无简介' : text,
              collapsedLines: collapsedLines,
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              DetailTagWrap(tags: tags),
            ],
          ],
        ),
      ),
    );
  }
}

/// 可展开/收起的长文本：默认折叠 [collapsedLines] 行。
///
/// 用 TextPainter 量一次是否超出：没超出就不显示「展开」，避免短简介下面挂
/// 一个点了没反应的按钮。
class ExpandableIntro extends StatefulWidget {
  const ExpandableIntro({
    super.key,
    required this.text,
    this.collapsedLines = 4,
  });

  final String text;
  final int collapsedLines;

  @override
  State<ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<ExpandableIntro> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ExpandableIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从 preview 切到接口数据后简介可能变长/变短，回到折叠态重新判断。
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var style = theme.textTheme.bodyMedium?.copyWith(height: 1.6);
    // 系统开了粗体时 TextPainter 与 Text 的样式必须一致，否则测量结果失真。
    if (MediaQuery.boldTextOf(context)) {
      style = (style ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: widget.collapsedLines,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                maxLines: _expanded ? null : widget.collapsedLines,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.primary,
                  ),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 区块标题行：左边标题，右边可选操作（如「共 N 章 · 查看全部」）。
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      detailGutter,
      detailGutter,
      detailGutter,
      4,
    ),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // trailing 靠右但不抢占固定宽度：窄屏/大字号下让它自己省略，
          // 而不是把标题挤没。
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// 标签小圆角 pill。Material 的 [Chip] 自带 48dp 点击区，一屏标签会撑出
/// 一大块空白，这里只画视觉（标签本身不可点）。
class DetailTagChip extends StatelessWidget {
  const DetailTagChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一组标签：自动换行。
class DetailTagWrap extends StatelessWidget {
  const DetailTagWrap({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final tag in tags) DetailTagChip(label: tag)],
    );
  }
}

/// 详情页最下方的资源 ID 卡片 + 一键复制。
///
/// 卡风格、不再带标题：左侧一个小的 `ID` 前缀 + 资源 ID（超长省略），右侧
/// 复制图标；放在内容最后、底部操作栏之上，反馈问题时能直接报出资源 ID。
/// [label] 只用于复制按钮的 tooltip / 读屏文案（「复制书籍 ID」）。
class DetailIdFooter extends StatelessWidget {
  const DetailIdFooter({
    super.key,
    required this.id,
    required this.label,
    this.bottomPadding = 26,
  });

  /// 完整资源 ID（复制用）。
  final String id;

  /// 资源类型：`书籍 ID` / `短剧 ID`，只给 tooltip 与读屏用。
  final String label;

  /// 与下方底部操作栏之间的留白。
  final double bottomPadding;

  /// 复制完整 ID 并给浮动 SnackBar 反馈。
  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    showAppSnackBar(context, 'ID 已复制', behavior: SnackBarBehavior.floating);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Card(
        margin: const EdgeInsets.fromLTRB(detailGutter, 6, detailGutter, 0),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          // 右侧少留：IconButton 自带内边距，图标视觉上仍贴着卡片右边。
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
          child: Row(
            children: [
              Text(
                'ID',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '复制$label',
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_rounded, size: 16),
                color: scheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
