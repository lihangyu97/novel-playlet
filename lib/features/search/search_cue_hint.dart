import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/search_cue.dart';
import 'search_providers.dart';

/// 搜索框的占位热词：按 cue 接口给的间隔逐条淡入淡出轮播。
///
/// 只做**占位（hint）**，不写进输入框；[fallback] 是接口没给词/失败时的静态
/// 提示语。[initialWord] 是从推荐页带进来的当前热词——搜索页打开时占位从同一条
/// 接着看，不会跳回第一条。[onWordChanged] 把当前显示的词报给页面，空输入提交
/// 时用它直接发起搜索。
class SearchCueHint extends ConsumerWidget {
  const SearchCueHint({
    super.key,
    required this.fallback,
    this.initialWord = '',
    this.onWordChanged,
  });

  final String fallback;
  final String initialWord;
  final ValueChanged<String>? onWordChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final cue = ref.watch(searchCueProvider).value ?? SearchCue.empty;
    if (cue.isEmpty) {
      return Text(
        fallback,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return _CueRotator(
      // 词组只在首次加载时变化；换成新词组才需要重建轮播状态。
      key: ObjectKey(cue.words),
      words: cue.words,
      intervalMs: cue.rotateIntervalMs,
      initialWord: initialWord,
      onWordChanged: onWordChanged,
      style: style,
    );
  }
}

class _CueRotator extends StatefulWidget {
  const _CueRotator({
    super.key,
    required this.words,
    required this.intervalMs,
    required this.style,
    this.initialWord = '',
    this.onWordChanged,
  });

  final List<String> words;
  final int intervalMs;
  final TextStyle? style;
  final String initialWord;
  final ValueChanged<String>? onWordChanged;

  @override
  State<_CueRotator> createState() => _CueRotatorState();
}

class _CueRotatorState extends State<_CueRotator> {
  /// 从带进来的那条开始（找不到就从第一条开始）。
  late int _index = _startIndex();
  Timer? _timer;

  String get _word => widget.words[_index];

  int _startIndex() {
    final index = widget.words.indexOf(widget.initialWord);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    // 首帧就把当前词报给页面：空输入提交时用得到。
    _reportWord();
    if (widget.words.length > 1) {
      _timer = Timer.periodic(
        Duration(milliseconds: widget.intervalMs),
        (_) => _tick(),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    // 被路由盖住（例如打开搜索页/详情页）时不翻；回来继续下一拍，不补帧。
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    setState(() => _index = (_index + 1) % widget.words.length);
    _reportWord();
  }

  void _reportWord() {
    // 这里只让页面记下"当前词"（普通字段赋值），不触发 setState：可以在
    // child 的 initState 里安全回调父页面。
    widget.onWordChanged?.call(_word);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      // 只做淡入淡出：占位文字来回滑动会抢注意力。
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      // 默认 layoutBuilder 是 Stack(alignment: center)，会把占位词居中；
      // 改成左对齐，和普通 hintText 的起始位置保持一致。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previousChildren, ?currentChild],
      ),
      child: Text(
        _word,
        key: ValueKey(_word),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      ),
    );
  }
}
