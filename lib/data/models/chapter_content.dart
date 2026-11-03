import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'json_utils.dart';

/// 一章正文。
class ChapterContent {
  const ChapterContent({
    required this.id,
    required this.title,
    required this.paragraphs,
  });

  final String id;
  final String title;

  /// 已清洗的段落（无 HTML 标签、无空段）。
  final List<String> paragraphs;

  bool get isEmpty => paragraphs.isEmpty;
}

/// 解析正文响应。
///
/// 优先图文接口 `/chapters/{id}/novel`：要求 `content_decrypted == true`，
/// 密文未解开时明确报错而不是把 base64 当正文显示。纯文字接口
/// `/chapters/{id}` 走同一套 HTML 清洗。
ChapterContent parseChapterContent(
  Map<String, dynamic> payload, {
  required String chapterId,
  String title = '',
}) {
  final data = unwrapEnvelope(payload);
  final decrypted = data['content_decrypted'];
  if (decrypted != null && decrypted != true) {
    throw ApiException('正文尚未解密');
  }
  final resolvedTitle =
      title.isNotEmpty ? title : firstString(data, ['title', 'chapter_title']);
  final html = firstString(data, ['content', 'chapter_content', 'text']);
  final paragraphs = _stripLeadingTitle(htmlToParagraphs(html), resolvedTitle);
  if (paragraphs.isEmpty) {
    throw ApiException('正文为空');
  }
  return ChapterContent(
    id: chapterId,
    title: resolvedTitle,
    paragraphs: paragraphs,
  );
}

/// 把正文 HTML 拍平成段落。
///
/// 上游正文是 `<p>` 段落 + `<br>` 换行的混合结构，还可能夹带 `<img>` 插图与
/// 水印 span。块级元素边界即段落边界，行内元素直接拼文本。
List<String> htmlToParagraphs(String html) {
  if (html.trim().isEmpty) return const [];
  final fragment = html_parser.parseFragment(html);
  final paragraphs = <String>[];
  final buffer = StringBuffer();

  void flush() {
    final text = _clean(buffer.toString());
    if (text.isNotEmpty) paragraphs.add(text);
    buffer.clear();
  }

  void walk(Node node) {
    if (node is Text) {
      // 上游正文里有把换行直接写进 <p> 文本的情况（不是 <br>）。不按换行切开
      // 的话，这几行会挤进同一个 block，只有首行有缩进，其余行贴左。
      final parts = node.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) flush();
        buffer.write(parts[i]);
      }
      return;
    }
    if (node is! Element) return;
    final tag = node.localName?.toLowerCase() ?? '';
    switch (tag) {
      case 'script':
      case 'style':
      case 'img':
      case 'figure':
      case 'figcaption':
        return;
      case 'br':
        flush();
        return;
      case 'p':
      case 'div':
      case 'section':
      case 'article':
      case 'li':
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
      case 'blockquote':
        flush();
        for (final child in node.nodes) {
          walk(child);
        }
        flush();
        return;
      default:
        for (final child in node.nodes) {
          walk(child);
        }
    }
  }

  for (final node in fragment.nodes) {
    walk(node);
  }
  flush();
  return paragraphs;
}

/// 上游正文 HTML 以 `<header><div class="tt-title">第1章 …</div></header>` 开头，
/// 页面已经单独渲染标题，这里把与标题重复的首段去掉。
List<String> _stripLeadingTitle(List<String> paragraphs, String title) {
  if (paragraphs.isEmpty || title.trim().isEmpty) return paragraphs;
  final first = paragraphs.first.replaceAll(RegExp(r'\s+'), '');
  final normalized = title.replaceAll(RegExp(r'\s+'), '');
  if (first == normalized) return paragraphs.sublist(1);
  return paragraphs;
}

String _clean(String raw) => raw
    .replaceAll('\u00a0', ' ')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\s*\n\s*'), '\n')
    .trim();
