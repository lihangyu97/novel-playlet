import 'dart:ui' show TextRange;

/// 正文对话扫描器：按段落顺序扫完整章，识别“人物说话内容”区间。
///
/// 中文网文的对话经常**跨段**：一个左引号在这一段打开、隔几段才闭合，甚至
/// 每段开头重复一个左引号、只在最后一段给右引号。所以对话状态必须跨段落
/// 延续，不能逐段独立配对：
///
/// ```text
/// “方公子！            ← 左引号，还没闭合
/// 城主大人让我再问一遍！  ← 整段都在说话内容里
/// 你去……还是不去？”     ← 到这里才闭合
/// ```
///
/// 支持成对 `“…”`、`「…」`、`『…』`；区间**不含引号本身**。未闭合引号只在
/// 本章内延续（换章/重新分页时换新扫描器），不会把状态带到别的章。
class ReaderDialogueScanner {
  /// 已打开、尚未闭合的引号（按嵌套层级从外到内）。
  final List<String> _openQuotes = <String>[];

  /// 本段内「说话内容」的起点；null 表示当前不在对话里。
  int? _speechStart;

  /// 扫描一段正文，返回这段里属于说话内容的区间（段内 offset）。
  ///
  /// 上一段没闭合的引号会让本段从 0 开始就是对话；本段结尾仍未闭合时，
  /// 返回「到段尾为止」的区间并把引号状态留给下一段。
  List<TextRange> scanParagraph(String text) {
    _speechStart = null;
    if (text.isEmpty) return const <TextRange>[];

    final ranges = <TextRange>[];
    var index = 0;
    if (_openQuotes.isNotEmpty) {
      _speechStart = 0;
      // 多段引语的排版习惯：续段开头重复一个同类型左引号，只有最后一段才
      // 闭合。这个重复的左引号是标记而不是新层级，不能再入栈，否则永远
      // 闭不上、后面整章都会被当成对话。
      final first = text[0];
      if (_openToClose.containsKey(first) && _openQuotes.last == first) {
        index = 1;
        _speechStart = 1;
      }
    }

    for (; index < text.length; index++) {
      final char = text[index];
      if (_openToClose.containsKey(char)) {
        _openQuotes.add(char);
        _speechStart ??= index + 1;
        continue;
      }
      final open = _closeToOpen[char];
      if (open == null) continue;
      // 从栈顶往回找同类型的左引号；找不到就忽略这个孤立的右引号。
      for (var depth = _openQuotes.length - 1; depth >= 0; depth--) {
        if (_openQuotes[depth] != open) continue;
        _openQuotes.removeRange(depth, _openQuotes.length);
        if (_openQuotes.isEmpty) {
          _emit(ranges, _speechStart ?? 0, index);
          _speechStart = null;
        }
        break;
      }
    }

    if (_openQuotes.isNotEmpty) {
      _emit(ranges, _speechStart ?? 0, text.length);
      // 状态跨段保留，但本段起点到这里为止，下一段重新起算。
      _speechStart = null;
    }
    return ranges;
  }

  void _emit(List<TextRange> ranges, int start, int end) {
    if (end > start) ranges.add(TextRange(start: start, end: end));
  }
}

/// 单段对话识别（不跨段）：成对引号包起来的说话内容，不含引号本身。
///
/// 阅读正文走 [ReaderDialogueScanner]，因为上面的真实源里对话常常跨段；
/// 这个入口留给单段调用与测试。
List<TextRange> findReaderDialogueRanges(String text) =>
    ReaderDialogueScanner().scanParagraph(text);

const Map<String, String> _openToClose = {'“': '”', '「': '」', '『': '』'};

const Map<String, String> _closeToOpen = {'”': '“', '」': '「', '』': '『'};
