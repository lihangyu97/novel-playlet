import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'json_utils.dart';

/// 章节正文缓存（`reader_chapters/` 与 `offline/novel/` 同构）的 schema 版本。
///
/// 版本 2 起落盘段评需要的段落锚点 `paraIndices`；读到没有 `v` 字段的老文件
/// （按 0 算）时，阅读页会在气泡开启时补取一次带锚点的正文。
const int chapterCacheSchemaVersion = 2;

/// 一章正文。
class ChapterContent {
  const ChapterContent({
    required this.id,
    required this.title,
    required this.paragraphs,
    this.paraIndices = const <int?>[],
  });

  final String id;
  final String title;

  /// 已清洗的段落（无 HTML 标签、无空段）。
  final List<String> paragraphs;

  /// 与 [paragraphs] 等长的上游段落 id（正文 `<p idx="N">`），没有就是 null。
  ///
  /// 段评按这个 id 对齐；空列表表示这份缓存没写过锚点字段（升级前缓存 /
  /// 离线旧文件）。纯文本源的解析结果是全 null 的列表，不是空列表。
  final List<int?> paraIndices;

  bool get isEmpty => paragraphs.isEmpty;

  /// 是否真的拿到了段落锚点（至少一段带 `<p idx>`）。
  ///
  /// 段评气泡与回填都只看这个：全 null 的列表（纯文本源）没有可用锚点，
  /// 不能拿它替换正在显示的离线/缓存正文。
  bool get hasAnchors => paraIndices.any((index) => index != null);

  /// 第 [position] 段的上游段落 id；越界或无锚点返回 null。
  int? paraIndexAt(int position) =>
      position >= 0 && position < paraIndices.length
      ? paraIndices[position]
      : null;
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
  final resolvedTitle = title.isNotEmpty
      ? title
      : firstString(data, ['title', 'chapter_title']);
  final html = firstString(data, ['content', 'chapter_content', 'text']);
  final parsed = _stripLeadingTitle(_parseHtmlParagraphs(html), resolvedTitle);
  if (parsed.texts.isEmpty) {
    throw ApiException('正文为空');
  }
  return ChapterContent(
    id: chapterId,
    title: resolvedTitle,
    paragraphs: parsed.texts,
    paraIndices: parsed.indices,
  );
}

/// 批量正文响应（`/api/v1/chapters/batch`）的解析结果：`itemId → 正文`。
///
/// 上游把每一章的正文放在 `data[itemId]` 里，内核已就地解密。这里做防御性
/// 解析：整包失败 / 某章未解密 / 正文为空的章**不出现**在结果里，由下载器
/// 逐章回退单章接口，避免一批里一章坏导致整批失败。
///
/// 章节标题优先取响应里的 title；缺失时由下载器用目录里的标题补齐。
Map<String, ChapterContent> parseBatchChapterContents(
  Map<String, dynamic> payload,
) {
  final out = <String, ChapterContent>{};
  Map<String, dynamic> data;
  try {
    data = unwrapEnvelope(payload);
  } catch (_) {
    // 整包失败 = 这批都没拿到；返回空表让调用方逐章回退。
    return out;
  }
  // 正常形态是 data 直接按 itemId 分组；兼容包了一层 item_infos 的响应。
  final items = asMap(data['item_infos']) ?? data;
  for (final entry in items.entries) {
    final json = asMap(entry.value);
    if (json == null) continue;
    // 内核 batch 接口会就地解密并写回 content；显式 false 才代表没解开。
    if (json['content_decrypted'] == false) continue;
    final html = firstString(json, ['content', 'chapter_content', 'text']);
    if (html.trim().isEmpty) continue;
    final title = firstString(json, ['title', 'chapter_title', 'name']);
    final parsed = _stripLeadingTitle(_parseHtmlParagraphs(html), title);
    if (parsed.texts.isEmpty) continue;
    out[entry.key] = ChapterContent(
      id: entry.key,
      title: title,
      paragraphs: List<String>.unmodifiable(parsed.texts),
      paraIndices: List<int?>.unmodifiable(parsed.indices),
    );
  }
  return out;
}

/// 一段正文 + 它的上游段落 id（`<p idx="N">`）。
class ParsedParagraphs {
  const ParsedParagraphs(this.texts, this.indices);

  final List<String> texts;
  final List<int?> indices;

  bool get isEmpty => texts.isEmpty;
}

/// 把正文 HTML 拍平成段落（不带段落 id 的兼容入口）。
List<String> htmlToParagraphs(String html) => _parseHtmlParagraphs(html).texts;

/// 把正文 HTML 拍平成段落，并保留 `<p idx="N">` 的段落 id。
///
/// 上游正文是 `<p>` 段落 + `<br>` 换行的混合结构，还可能夹带 `<img>` 插图与
/// 水印 span。块级元素边界即段落边界，行内元素直接拼文本。
///
/// 段落 id 是段评的锚点：标题（`<header><div class=tt-title>`）没有 idx，
/// 一个 `<p>` 被换行拆成多段时只有第一段拿 id——与官方解析口径一致。
ParsedParagraphs _parseHtmlParagraphs(String html) {
  if (html.trim().isEmpty) return const ParsedParagraphs([], []);
  final fragment = html_parser.parseFragment(html);
  final texts = <String>[];
  final indices = <int?>[];
  final buffer = StringBuffer();
  int? pendingIndex;

  void flush() {
    final text = _clean(buffer.toString());
    if (text.isNotEmpty) {
      texts.add(text);
      indices.add(pendingIndex);
      pendingIndex = null;
    }
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
        pendingIndex = int.tryParse(node.attributes['idx'] ?? '');
        for (final child in node.nodes) {
          walk(child);
        }
        flush();
        pendingIndex = null;
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
  return ParsedParagraphs(texts, indices);
}

/// 上游正文 HTML 以 `<header><div class="tt-title">第1章 …</div></header>` 开头，
/// 页面已经单独渲染标题，这里把与标题重复的首段去掉（段落 id 同步去掉）。
ParsedParagraphs _stripLeadingTitle(ParsedParagraphs parsed, String title) {
  if (parsed.isEmpty || title.trim().isEmpty) return parsed;
  final first = parsed.texts.first.replaceAll(RegExp(r'\s+'), '');
  final normalized = title.replaceAll(RegExp(r'\s+'), '');
  if (first == normalized) {
    return ParsedParagraphs(parsed.texts.sublist(1), parsed.indices.sublist(1));
  }
  return parsed;
}

String _clean(String raw) => raw
    .replaceAll('\u00a0', ' ')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\s*\n\s*'), '\n')
    .trim();
