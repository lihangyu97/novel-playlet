import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'cover_hero.dart';
import 'novel_cover.dart';
import 'surface_card.dart';

/// 小说 / 短剧列表卡片的共用骨架：封面 + 标题 + 元信息。
///
/// 两种形态共存，靠 [surface] / [naturalTitleHeight] 切：
/// - 紧凑网格（默认）：封面 + 标题 + 元信息直接铺在画布上，标题固定占两行，
///   同一排卡片元信息行对齐；书架等入口用它。
/// - 白底卡片（推荐流）：[AppSurfaceCard] 兜底，封面满宽出血、顶部圆角随卡片、
///   底部直角，文字区单独留内边距；标题按 1~2 行自然高度，卡片高度由内容
///   决定，高低差交给瀑布流布局吸收。
///
/// 两侧只有元信息不同（小说是作者、短剧是集数），字号与间距完全一致：
/// - 紧凑网格下封面比例也一致（都走 [kCoverAspect]），所以同一排卡片尺寸
///   不会跳；
/// - 推荐流按内容域原生比例出图（[kNovelCoverAspect] / [kVideoCoverAspect]），
///   小说与短剧卡的封面高度**故意不同**，这是瀑布流错落的一部分。
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.cover,
    required this.title,
    required this.width,
    required this.onTap,
    this.meta,
    this.heroTag,
    this.cornerText,
    this.coverAspect = kCoverAspect,
    this.surface = false,
    this.naturalTitleHeight = false,
  });

  final String cover;
  final String title;
  final double width;
  final VoidCallback onTap;

  /// 元信息文案；null = 不占这一行。
  ///
  /// 紧凑网格里空串 = 占一行但没字：小说侧作者与分类都为空时要保持那一行
  /// 间距和原版式；短剧缺集数传 null（不能硬凑空行，否则卡片底部多出空白）。
  /// 卡片化形态（[surface]）下空串也按"没有"处理——高度由内容决定，
  /// 留一行空白会让卡片莫名变高。
  final String? meta;

  /// 封面 Hero tag；null = 不参与飞入动画（例如深链/无列表来源）。
  final String? heroTag;

  /// 封面右上角角标文案（如评分「9.3分」）；null / 空串不显示。
  ///
  /// 白字 + 半透明深色底 + 轻阴影：封面颜色不可控，纯白字直接压图容易糊。
  final String? cornerText;

  /// 封面高 / 宽；默认 [kCoverAspect]。
  ///
  /// 推荐流按内容域原生比例传 [kNovelCoverAspect] / [kVideoCoverAspect]：
  /// 封面不被裁切，卡片也自然有高低差；其它固定网格入口保持默认。
  final double coverAspect;

  /// 是否画成白底卡片（推荐流开启，书架等入口暂不开启）。
  final bool surface;

  /// 标题是否按内容自然高度（1~2 行）排列。
  ///
  /// 关闭时固定占两行（同排卡片元信息对齐）；开启后卡片高度随内容变化，
  /// 由瀑布流布局吸收高低差。
  final bool naturalTitleHeight;

  /// 标题行高倍数；紧凑网格的固定高度与瀑布流布局的高度预算口径都按它算。
  static const double titleLineHeightFactor = 1.25;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final coverHeight = width * coverAspect;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: titleLineHeightFactor,
    );
    // 紧凑网格把标题盒固定撑成两行：书名只有一行时也把标题与元信息的间距
    // 撑开，同一行卡片的元信息行才会对齐。
    final textScaler = MediaQuery.textScalerOf(context);
    final titleLineHeight =
        textScaler.scale(titleStyle?.fontSize ?? 14) * titleLineHeightFactor;

    final coverWidget = CoverHero(
      tag: heroTag,
      child: Stack(
        children: [
          NovelCover(
            url: cover,
            width: width,
            height: coverHeight,
            // 卡片化时封面满宽出血，圆角交给卡片裁：顶部随卡片圆角、底部直角。
            radius: surface ? 0 : kCoverRadius,
          ),
          if (cornerText != null && cornerText!.isNotEmpty)
            Positioned(top: 6, right: 6, child: _CornerBadge(cornerText!)),
        ],
      ),
    );

    final titleWidget = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );

    // 卡片化 + 自然高度时，空串元信息也当"没有"处理：否则会留一行空白，
    // 与"高度由内容决定"相悖。紧凑网格仍保留空串占位，保证同一排元信息对齐。
    final metaText = meta;
    final metaWidget = metaText == null || (surface && metaText.isEmpty)
        ? null
        : Text(
            metaText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          );

    final titleBlock = naturalTitleHeight
        ? titleWidget
        : SizedBox(height: titleLineHeight * 2, child: titleWidget);

    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        titleBlock,
        if (metaWidget != null) ...[const SizedBox(height: 3), metaWidget],
      ],
    );

    // 卡片化时封面贴边、文字区单独留内边距；紧凑网格保持原来的 8pt 间距。
    final content = surface
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              coverWidget,
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: textBlock,
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [coverWidget, const SizedBox(height: 8), textBlock],
          );

    if (!surface) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: SizedBox(width: width, child: content),
      );
    }
    return SizedBox(
      width: width,
      child: AppSurfaceCard(onTap: onTap, child: content),
    );
  }
}

/// 卡片元信息行里的评分文案：上游 `score` 是字符串，`0` / `0.0` / 空都算
/// 未评分；有值时补「分」，避免和集数/字数等纯数字混淆。
String scoreLabel(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value == '0' || value == '0.0') return '';
  return '$value分';
}

/// 封面右上角角标：白字 + 半透明深色底 + 轻阴影。
class _CornerBadge extends StatelessWidget {
  const _CornerBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        text,
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
