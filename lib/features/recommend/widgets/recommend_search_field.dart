import 'package:flutter/material.dart';

/// 顶部搜索框：固定在页面顶部，不随列表滚动。
///
/// 输入文本是纯 UI 状态，留在 TextEditingController；提交/清空/取消都只是
/// 回调，由页面翻译成 provider 操作。
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
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            // 高度写死 48（与 IconButton 的最小触控高度一致）：既不会被清空
            // 按钮撑高，也不会因为内容的内边距比按钮矮而显得文字偏上。
            child: SizedBox(
              height: 48,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                textAlignVertical: TextAlignVertical.center,
                style: theme.textTheme.bodyMedium,
                onSubmitted: onSubmitted,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '搜索书名/作者',
                  hintStyle: hintStyle,
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox.shrink();
                      return IconButton(
                        tooltip: '清空',
                        // 40x40 以内：和空态同高，且不吃掉行高。
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        iconSize: 18,
                        icon: Icon(
                          Icons.cancel_rounded,
                          size: 17,
                          color: scheme.onSurfaceVariant,
                        ),
                        onPressed: onClear,
                      );
                    },
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
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
