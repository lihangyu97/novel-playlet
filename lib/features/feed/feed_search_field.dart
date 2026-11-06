import 'package:flutter/material.dart';

/// 推荐页顶部搜索框（小说/短剧/漫剧分类共用）。
///
/// 输入文本是纯 UI 状态，留在 TextEditingController；提交/清空/取消都只是
/// 回调，由页面翻译成 provider 操作。
///
/// 结构刻意不用 `InputDecoration` 的 prefix/suffixIcon：
///   - suffix 的 `IconButton` 有最小触控尺寸，输入后会把整行撑高；
///   - prefixIcon 在固定高度里不垂直居中。
/// 改成 Row 自己排：固定 [height] 高，图标/输入/清空都在同一行里垂直居中。
///
/// 高度从 48 收到 40：搜索框是每屏都占着的常驻元素，iOS 原生搜索栏内容高
/// 一般 36–40；40pt 仍远大于触控下限，且页面滚动时会整条收起（见 RecommendPage）。
class FeedSearchField extends StatelessWidget {
  const FeedSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onSubmitted,
    required this.onClear,
    required this.onCancel,
    required this.showCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final VoidCallback onCancel;
  final bool showCancel;

  static const double height = 40;

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
            // 只留底色不画描边：iOS 搜索栏观感，避免和列表卡片分隔线叠在一起。
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      textInputAction: TextInputAction.search,
                      textAlignVertical: TextAlignVertical.center,
                      style: theme.textTheme.bodyMedium,
                      onSubmitted: onSubmitted,
                      // collapsed：去掉 decoration 自带的上下留白，行高由外层
                      // 40pt 决定，文字自然垂直居中。
                      decoration: InputDecoration.collapsed(
                        hintText: hintText,
                        hintStyle: hintStyle,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      if (value.text.isEmpty) return const SizedBox(width: 8);
                      return IconButton(
                        tooltip: '清空',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
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
            // 搜索态的「取消」不能把搜索行撑高：按钮固定 36 高、去掉默认留白。
            child: TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('取消'),
            ),
          ),
      ],
    );
  }
}
