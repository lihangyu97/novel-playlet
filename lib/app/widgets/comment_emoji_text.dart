import 'package:flutter/material.dart';

/// 上游评论正文用 `[微笑]` 这类方括号 token 表示官方表情。
///
/// 官方客户端用 `\[[A-Z一-龥]+\]` 识别（`is4/i.java`），这里保持同一口径：
/// 只处理官方 token 形状，避免把正文里普通的中文方括号内容误当表情。
final RegExp commentEmojiPattern = RegExp(r'\[[A-Z一-龥]+\]');

/// token → 包内表情图。
///
/// 53 张图是从 fqapp 的 `drawable-xxhdpi` 原样抽出的 120×120 webp，编号对应
/// `emoji_config.json` 的顺序；全部打进包（合计约 126 KB），评论离线也能渲染。
const Map<String, String> commentEmojiAssets = {
  '[微笑]': 'assets/images/emoji/emoji_01.webp',
  '[偷笑]': 'assets/images/emoji/emoji_02.webp',
  '[笑]': 'assets/images/emoji/emoji_03.webp',
  '[什么]': 'assets/images/emoji/emoji_04.webp',
  '[害羞]': 'assets/images/emoji/emoji_05.webp',
  '[爱慕]': 'assets/images/emoji/emoji_06.webp',
  '[飞吻]': 'assets/images/emoji/emoji_07.webp',
  '[奸笑]': 'assets/images/emoji/emoji_08.webp',
  '[尬笑]': 'assets/images/emoji/emoji_09.webp',
  '[思考]': 'assets/images/emoji/emoji_10.webp',
  '[撇嘴]': 'assets/images/emoji/emoji_11.webp',
  '[做鬼脸]': 'assets/images/emoji/emoji_12.webp',
  '[酷]': 'assets/images/emoji/emoji_13.webp',
  '[翻白眼]': 'assets/images/emoji/emoji_14.webp',
  '[惊呆]': 'assets/images/emoji/emoji_15.webp',
  '[震惊]': 'assets/images/emoji/emoji_16.webp',
  '[送心]': 'assets/images/emoji/emoji_17.webp',
  '[委屈]': 'assets/images/emoji/emoji_18.webp',
  '[快哭了]': 'assets/images/emoji/emoji_19.webp',
  '[笑哭]': 'assets/images/emoji/emoji_20.webp',
  '[哭]': 'assets/images/emoji/emoji_21.webp',
  '[大笑]': 'assets/images/emoji/emoji_22.webp',
  '[舔屏]': 'assets/images/emoji/emoji_23.webp',
  '[怒]': 'assets/images/emoji/emoji_24.webp',
  '[捂脸]': 'assets/images/emoji/emoji_25.webp',
  '[吐]': 'assets/images/emoji/emoji_26.webp',
  '[恐惧]': 'assets/images/emoji/emoji_27.webp',
  '[抓狂]': 'assets/images/emoji/emoji_28.webp',
  '[敬礼]': 'assets/images/emoji/emoji_29.webp',
  '[石化]': 'assets/images/emoji/emoji_30.webp',
  '[OK]': 'assets/images/emoji/emoji_31.webp',
  '[赞]': 'assets/images/emoji/emoji_32.webp',
  '[爱心]': 'assets/images/emoji/emoji_33.webp',
  '[伤心]': 'assets/images/emoji/emoji_34.webp',
  '[KISS]': 'assets/images/emoji/emoji_35.webp',
  '[懂了]': 'assets/images/emoji/emoji_36.webp',
  '[探究]': 'assets/images/emoji/emoji_37.webp',
  '[重拳出击]': 'assets/images/emoji/emoji_38.webp',
  '[吃瓜]': 'assets/images/emoji/emoji_39.webp',
  '[盯]': 'assets/images/emoji/emoji_40.webp',
  '[你细品]': 'assets/images/emoji/emoji_41.webp',
  '[赶稿中]': 'assets/images/emoji/emoji_42.webp',
  '[注意]': 'assets/images/emoji/emoji_43.webp',
  '[饱了]': 'assets/images/emoji/emoji_44.webp',
  '[码住]': 'assets/images/emoji/emoji_45.webp',
  '[学会了]': 'assets/images/emoji/emoji_46.webp',
  '[顶帖]': 'assets/images/emoji/emoji_47.webp',
  '[求爆更]': 'assets/images/emoji/emoji_48.webp',
  '[求关注]': 'assets/images/emoji/emoji_49.webp',
  '[我也强推]': 'assets/images/emoji/emoji_50.webp',
  '[雀食神作]': 'assets/images/emoji/emoji_51.webp',
  '[已种草]': 'assets/images/emoji/emoji_52.webp',
  '[书架加一]': 'assets/images/emoji/emoji_53.webp',
};

bool hasCommentEmoji(String text) => commentEmojiPattern.hasMatch(text);

/// 把正文拆成普通文字和表情图 span。
///
/// 只有官方收录的 token 才换成图片；未知的方括号内容原样保留，避免上游以后
/// 新增表情时把正文吞掉。图片按正文字号的 1.4 倍渲染，与官方比例一致。
List<InlineSpan> commentEmojiSpans(String text, {required double fontSize}) {
  final size = fontSize * 1.4;
  final spans = <InlineSpan>[];
  var start = 0;
  for (final match in commentEmojiPattern.allMatches(text)) {
    if (match.start > start) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
    }
    final token = match.group(0)!;
    final asset = commentEmojiAssets[token];
    spans.add(
      asset == null
          ? TextSpan(text: token)
          : WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Image.asset(
                asset,
                width: size,
                height: size,
                semanticLabel: token,
                filterQuality: FilterQuality.medium,
              ),
            ),
    );
    start = match.end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans;
}

/// 评论/回复正文：有表情 token 时走富文本，没有时保持普通 [Text]。
///
/// 无 token 的评论保留原来的 [Text] 路径，布局、选中和 `find.text` 都不变；
/// 有 token 时把 [maxLines]/[overflow] 透传给富文本，截断行为与普通文字一致。
class CommentEmojiText extends StatelessWidget {
  const CommentEmojiText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (!hasCommentEmoji(text)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: commentEmojiSpans(text, fontSize: style?.fontSize ?? 16),
      ),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
