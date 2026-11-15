import 'package:flutter/material.dart';

/// 搜索页的搜索框（推荐页的搜索入口已收敛成顶栏一个图标按钮，不再用整行
/// 输入框）。
///
/// 文本留在页面自己的 `TextEditingController`，提交/清空/取消都只是回调，
/// 由页面翻译成搜索状态。
///
/// 结构刻意不用 `InputDecoration` 的 prefix/suffixIcon：
///   - suffix 的 `IconButton` 有最小触控尺寸，输入后会把整行撑高；
///   - prefixIcon 在固定高度里不垂直居中。
/// 改成 Row 自己排：固定 [height] 高，图标/输入/清空都在同一行里垂直居中。
///
/// 高度 40：iOS 原生搜索栏内容高一般 36–40；40pt 仍远大于触控下限。
/// 圆角 [radius] 从整圆（高的一半）收到 10，与推荐页顶栏的搜索入口一致。
class FeedSearchField extends StatelessWidget {
  const FeedSearchField({
    super.key,
    required this.hintText,
    this.controller,
    this.focusNode,
    this.onSubmitted,
    this.onClear,
    this.onCancel,
    this.showCancel = false,
    this.autofocus = false,
    this.hint,
  });

  final String hintText;

  /// 输入框控制器：页面用它读取/清空文本。
  final TextEditingController? controller;

  /// 输入框焦点：由页面持有（提交后 unfocus）。
  final FocusNode? focusNode;

  /// 键盘提交回调。
  final ValueChanged<String>? onSubmitted;

  /// 「清空」回调；null = 不显示清空按钮。
  final VoidCallback? onClear;

  /// 「取消」回调；null = 不显示取消按钮。
  final VoidCallback? onCancel;

  /// 是否显示右侧「取消」；默认不显示，独立搜索页常显。
  final bool showCancel;

  /// 进入页面时自动聚焦（搜索页需要直接弹键盘）。
  final bool autofocus;

  /// 自定义占位内容（例如轮播热词）；null = 用 [hintText] 的静态文案。
  ///
  /// 只在输入框为空时显示，样式由传进来的 widget 自己负责（搜索页的
  /// `SearchCueHint` 会按主题取 bodyMedium + onSurfaceVariant）。
  final Widget? hint;

  static const double height = 40;

  /// 搜索框圆角；推荐页顶栏的搜索入口也用这个值，两块圆角一致。
  static const double radius = 10;

  /// 搜索框 / 推荐页搜索入口的底色。
  ///
  /// 浅色主题用**纯白**（顶部有淡蓝粉渐变时白块更干净）；深色主题保持
  /// 深色容器底，避免一块纯白在暗色页里刺眼。
  static Color surfaceColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHighest
        : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final controller = this.controller;
    final clear = onClear;
    final cancel = onCancel;

    final bar = Row(
      children: [
        Expanded(
          child: DecoratedBox(
            // 只留底色不画描边：iOS 搜索栏观感，避免和列表卡片分隔线叠在一起。
            decoration: BoxDecoration(
              color: FeedSearchField.surfaceColor(context),
              borderRadius: BorderRadius.circular(radius),
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
                      autofocus: autofocus,
                      textInputAction: TextInputAction.search,
                      textAlignVertical: TextAlignVertical.center,
                      style: theme.textTheme.bodyMedium,
                      onSubmitted: onSubmitted,
                      // collapsed：去掉 decoration 自带的上下留白，行高由外层
                      // 40pt 决定，文字自然垂直居中。
                      decoration: hint == null
                          ? InputDecoration.collapsed(
                              hintText: hintText,
                              hintStyle: hintStyle,
                            )
                          : InputDecoration.collapsed(
                              hintText: null,
                              hintStyle: hintStyle,
                            ).copyWith(hint: hint),
                    ),
                  ),
                  // 没有可清空的输入（或没给回调）就只占位、不显示按钮。
                  if (controller != null && clear != null)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        if (value.text.isEmpty) {
                          return const SizedBox(width: 8);
                        }
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
                          onPressed: clear,
                        );
                      },
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
        if (showCancel && cancel != null)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            // 搜索态的「取消」不能把搜索行撑高：按钮固定 36 高、去掉默认留白。
            child: TextButton(
              onPressed: cancel,
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
    return bar;
  }
}
