import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'cover_hero.dart';
import 'novel_cover.dart';

/// 小说 / 短剧列表卡片的共用骨架：封面 + 两行标题 + 一行元信息。
///
/// 两侧只有元信息不同（小说是作者、短剧是集数），封面比例、圆角、字号与间距
/// 完全一致（都走 [kCoverAspect] / [AppTheme.cardRadius]），推荐页切分类时
/// 卡片尺寸才不会跳。
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.cover,
    required this.title,
    required this.width,
    required this.onTap,
    this.meta,
    this.heroTag,
  });

  final String cover;
  final String title;
  final double width;
  final VoidCallback onTap;

  /// 元信息文案；null = 不占这一行，空串 = 占一行但没字。
  ///
  /// 需要区分两者：短剧缺集数时不能硬凑空行（否则卡片底部多出 3pt 空白且
  /// 高度不齐），小说侧作者与分类都为空时却要保持那一行间距和原版式。
  final String? meta;

  /// 封面 Hero tag；null = 不参与飞入动画（例如深链/无列表来源）。
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverHeight = width * kCoverAspect;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverHero(
              tag: heroTag,
              child: NovelCover(url: cover, width: width, height: coverHeight),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (meta != null) ...[
              const SizedBox(height: 3),
              Text(
                meta!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
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
