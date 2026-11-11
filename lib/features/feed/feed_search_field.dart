import 'package:flutter/material.dart';

/// 搜索框（推荐页入口 / 独立搜索页共用）。
///
/// 两种形态：
/// - **可输入**（独立搜索页）：文本留在页面自己的 `TextEditingController`，
///   提交/清空/取消都只是回调，由页面翻译成搜索状态；
/// - **只读入口**（推荐页）：[readOnly] + [onTap]，点一下跳独立搜索页。只读
///   形态不弹键盘、不显示光标/清空按钮，外观与可输入形态完全一致，所以推荐
///   页不需要为「点开搜索」另写一套假搜索栏。
///
/// 结构刻意不用 `InputDecoration` 的 prefix/suffixIcon：
///   - suffix 的 `IconButton` 有最小触控尺寸，输入后会把整行撑高；
///   - prefixIcon 在固定高度里不垂直居中。
/// 改成 Row 自己排：固定 [height] 高，图标/输入/清空都在同一行里垂直居中。
///
/// 高度 40：搜索框是每屏都占着的常驻元素，iOS 原生搜索栏内容高一般 36–40；
/// 40pt 仍远大于触控下限。圆角 [radius] 从整圆（高的一半）收到 10，与右侧
/// 缓存中心入口保持一致；搜索框常驻顶部，不再随列表滚动收起。
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
    this.readOnly = false,
    this.autofocus = false,
    this.onTap,
    this.hint,
  });

  final String hintText;

  /// 输入框控制器：可输入形态用它读取/清空文本，只读入口不需要。
  final TextEditingController? controller;

  /// 输入框焦点：可输入形态由页面持有（提交后 unfocus），只读入口不需要。
  final FocusNode? focusNode;

  /// 键盘提交回调；只读入口为 null。
  final ValueChanged<String>? onSubmitted;

  /// 「清空」回调；null（或只读形态）= 不显示清空按钮。
  final VoidCallback? onClear;

  /// 「取消」回调；null = 不显示取消按钮。
  final VoidCallback? onCancel;

  /// 是否显示右侧「取消」；默认不显示，独立搜索页常显。
  final bool showCancel;

  /// 只读入口：不弹键盘、不显示光标与清空按钮，只响应 [onTap]。
  final bool readOnly;

  /// 进入页面时自动聚焦（独立搜索页需要直接弹键盘）。
  final bool autofocus;

  /// 只读入口的点击回调；可输入形态通常为 null。
  final VoidCallback? onTap;

  /// 自定义占位内容（例如轮播热词）；null = 用 [hintText] 的静态文案。
  ///
  /// 只在输入框为空时显示，样式由传进来的 widget 自己负责（搜索页的
  /// `SearchCueHint` 会按主题取 bodyMedium + onSurfaceVariant）。
  final Widget? hint;

  static const double height = 40;

  /// 搜索框圆角；右侧缓存中心图标入口也用这个值，两块并排时圆角一致。
  static const double radius = 10;

  /// 搜索框 / 缓存中心图标按钮底色。
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
                      // 只读入口：可以点、不能编辑，也不弹出键盘/光标。
                      readOnly: readOnly,
                      autofocus: autofocus,
                      canRequestFocus: !readOnly,
                      showCursor: !readOnly,
                      enableInteractiveSelection: !readOnly,
                      onTap: onTap,
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
                  // 清空只属于可输入形态：只读入口没有可清空的输入，也没有
                  // 回调，就不占位、不显示。
                  if (!readOnly && controller != null && clear != null)
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
    if (!readOnly || onTap == null) return bar;
    // 只读入口整条都可点：左图标、留白区域不落在 TextField 上，也要能进搜索页
    // （TextField 自己抢到的点击仍走它的 onTap，进的是同一个页面）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: bar,
    );
  }
}
