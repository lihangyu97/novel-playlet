import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 区块标题行：左侧标题，右侧可选操作（`trailing`）或说明文字（`hint`）。
///
/// 全 App 的「简介 / 书评 / 目录 / 选集 / 最近阅读 / 设置分区 / 搜索结果」
/// 共用这一套：标题统一 `titleMedium` + w600、单行省略；右侧控件靠右，窄屏
/// 或大字号下标题自己收缩，不会把右侧挤没。左右/上下留白由调用方按所在容器
/// 传（卡片内、页面左右、列表里各不相同）。
///
/// [titleSuffix] 紧跟在标题后面（如「收藏 8 条」里的条数），与右侧的
/// `trailing` 操作分开：数量属于标题，操作贴右。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.titleSuffix,
    this.trailing,
    this.hint,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 12),
  });

  final String title;

  /// 标题后的附加内容（计数 / 状态等），不会把 [trailing] 往左推。
  final Widget? titleSuffix;

  /// 右侧任意控件（按钮 / 计数等）。与 [hint] 二选一，[trailing] 优先。
  final Widget? trailing;

  /// 右侧说明文字（灰色小字，如「共 24 章」「2.6万人点评」）。
  final String? hint;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hintText = hint;
    final Widget? end =
        trailing ??
        (hintText == null
            ? null
            : Text(
                hintText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ));
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: context.appWeight(FontWeight.w600),
                    ),
                  ),
                ),
                if (titleSuffix != null) ...[
                  const SizedBox(width: 6),
                  titleSuffix!,
                ],
              ],
            ),
          ),
          if (end != null) ...[const SizedBox(width: 8), end],
        ],
      ),
    );
  }
}
