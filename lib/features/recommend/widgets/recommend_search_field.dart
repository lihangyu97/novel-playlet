import 'package:flutter/material.dart';

/// 顶部搜索框：固定在页面顶部，不随列表滚动。
///
/// 输入文本是纯 UI 状态，留在 TextEditingController；提交/清空/取消都只是
/// 回调，由页面翻译成 provider 操作。
///
/// 结构刻意不用 `InputDecoration` 的 prefix/suffixIcon：
///   - suffix 的 `IconButton` 有最小触控尺寸，输入后会把整行撑高；
///   - prefixIcon 在固定高度里不垂直居中（实测文字高 4pt、图标高 6pt）。
/// 改成 Row 自己排：固定 48pt 高，图标/输入/清空都在同一行里垂直居中。
class RecommendSearchField extends StatelessWidget {
  const RecommendSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onClear,
    required this.onCancel,
    required this.showCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final VoidCallback onCancel;
  final bool showCancel;

  static const double _height = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Row(
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(_height / 2),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: SizedBox(
              height: _height,
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      textInputAction: TextInputAction.search,
                      textAlignVertical: TextAlignVertical.center,
                      style: theme.textTheme.bodyMedium,
                      onSubmitted: onSubmitted,
                      // collapsed：去掉 decoration 自带的上下留白，行高由外层
                      // 48pt 决定，文字自然垂直居中。
                      decoration: InputDecoration.collapsed(
                        hintText: '搜索书名/作者',
                        hintStyle: hintStyle,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox(width: 12);
                      return IconButton(
                        tooltip: '清空',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        iconSize: 18,
                        icon: Icon(
                          Icons.cancel_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                        onPressed: onClear,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
        if (showCancel)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: TextButton(onPressed: onCancel, child: const Text('取消')),
          ),
      ],
    );
  }
}
