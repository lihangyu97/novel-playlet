import 'dart:ui' show TextRange;

/// 正文里的“人物说话内容”区间：成对双引号包起来的部分。
///
/// 中文网文/出版物的对话通常用 `“…”`，也兼容 `「…」`、`『…』`（部分源/繁中）。
/// 区间**不包含引号本身**，只描引号里的说话内容；引号未闭合、空引号
/// `“”` 都忽略，避免把整段误标成对话。
///
/// 嵌套引号（`“他说：“走吧。””`）按栈配对：内层先产出区间，外层再产出一个
/// 大区间；渲染侧会把同一行的矩形合并，不会出现重复加深。
List<TextRange> findReaderDialogueRanges(String text) {
  if (text.isEmpty) return const <TextRange>[];
  final ranges = <TextRange>[];
  final stack = <(int, String)>[];
  for (var index = 0; index < text.length; index++) {
    final char = text[index];
    if (_openToClose.containsKey(char)) {
      stack.add((index, char));
      continue;
    }
    final open = _closeToOpen[char];
    if (open == null) continue;
    for (var depth = stack.length - 1; depth >= 0; depth--) {
      if (stack[depth].$2 != open) continue;
      final start = stack[depth].$1;
      // 当前右引号配到这一层的左引号：把更深层未闭合的引号一起丢掉。
      stack.removeRange(depth, stack.length);
      // start 是左引号、index 是右引号，正文区间是 (start, index)。
      if (index - start > 1) {
        ranges.add(TextRange(start: start + 1, end: index));
      }
      break;
    }
  }
  return ranges;
}

const Map<String, String> _openToClose = {'“': '”', '「': '」', '『': '』'};

const Map<String, String> _closeToOpen = {'”': '“', '」': '「', '』': '『'};
