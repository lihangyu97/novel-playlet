import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'comment_emoji_text.dart';
import 'comment_image_strip.dart';
import '../../data/models/book_comment.dart';

/// 一条评论（书评 / 剧评 / 章评 / 段评 / 回复）的统一排版。
///
/// 全部评论列表（`CommentListSheet`）与详情页书评卡片共用：头像（昵称首字，
/// 不拉网络图）+ 昵称 +（作者标）+ 评分 + 时间，正文走官方表情渲染，配图缩略
/// 图，底部点赞数；回复列表由调用方通过 [replies] 传入（弹层里展开/收起）。
///
/// 颜色：默认跟随 App 主题；阅读页按纸色传 [foreground]（说明文字和分割线由
/// 它派生透明度），保证夜间/护眼底色上仍然可读。详情页与弹层是同一套排版，
/// 点「查看全部」不会出现行样式跳变。
class CommentRow extends StatelessWidget {
  const CommentRow({
    super.key,
    required this.comment,
    this.foreground,
    this.score,
    this.maxLines,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 6),
    this.showAuthorBadge = true,
    this.onToggleReplies,
    this.repliesExpanded = false,
    this.replies,
  });

  final BookComment comment;

  /// 前景色；null = `colorScheme.onSurface`。
  final Color? foreground;

  /// 昵称右侧的特殊项（如 5 星评分）。短剧评论没有评分，传 null。
  final Widget? score;

  /// 正文行数上限；null = 不限制（弹层里完整展示）。
  final int? maxLines;

  final EdgeInsetsGeometry padding;

  /// 昵称后是否显示「作者」标（官方作者回复）。
  final bool showAuthorBadge;

  /// 回复入口：null = 不显示（详情页卡片）。
  final VoidCallback? onToggleReplies;
  final bool repliesExpanded;

  /// 展开后的回复区（由调用方构建）。
  final Widget? replies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ?? scheme.onSurface;
    final name = comment.userName.trim().isEmpty
        ? '匿名读者'
        : comment.userName.trim();
    final text = comment.text.trim();
    final time = comment.timeLabel();
    final muted = fg.withValues(alpha: 0.5);
    final metaStyle = TextStyle(fontSize: 11, color: muted);
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommentAvatar(name: name, scheme: scheme, radius: 17),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            key: ValueKey('comment-name-${comment.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: context.appWeight(FontWeight.w600),
                              color: fg,
                            ),
                          ),
                        ),
                        if (showAuthorBadge && comment.isAuthor) ...[
                          const SizedBox(width: 4),
                          _AuthorBadge(scheme: scheme),
                        ],
                        if (score != null) ...[
                          const SizedBox(width: 6),
                          score!,
                        ],
                        if (time.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            time,
                            key: ValueKey('comment-time-${comment.id}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: fg.withValues(alpha: 0.45),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      CommentEmojiText(
                        text: text,
                        maxLines: maxLines,
                        overflow: maxLines == null
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, height: 1.5, color: fg),
                      ),
                    ],
                    if (comment.imageUrls.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      CommentImageStrip(
                        imageRefs: comment.imageRefsOrFallback,
                        placeholderColor: fg.withValues(alpha: 0.06),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.thumb_up_alt_outlined,
                          size: 13,
                          color: muted,
                        ),
                        const SizedBox(width: 3),
                        Text('${comment.diggCount}', style: metaStyle),
                        if (onToggleReplies != null &&
                            comment.replyCount > 0) ...[
                          const Spacer(),
                          InkWell(
                            onTap: onToggleReplies,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                repliesExpanded
                                    ? '收起回复'
                                    : '${comment.replyCount} 条回复',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          ?replies,
        ],
      ),
    );
  }
}

/// 首字头像：用昵称第一个字，不拉网络图（列表里也不为几条评论再开图片请求）。
class CommentAvatar extends StatelessWidget {
  const CommentAvatar({
    super.key,
    required this.name,
    required this.scheme,
    required this.radius,
  });

  final String name;
  final ColorScheme scheme;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '匿'
        : String.fromCharCode(trimmed.runes.first);
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primary.withValues(alpha: 0.12),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.8,
          fontWeight: context.appWeight(FontWeight.w600),
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _AuthorBadge extends StatelessWidget {
  const _AuthorBadge({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '作者',
        style: TextStyle(fontSize: 10, height: 1.2, color: scheme.primary),
      ),
    );
  }
}
