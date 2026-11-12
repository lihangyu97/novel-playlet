import 'package:flutter/material.dart';

import '../../../app/widgets/app_snack_bar.dart';

enum _ManageAction { openDetail, remove }

/// 长按管理菜单：书架/收藏共用同一套底部弹层。
///
/// 两侧只有「动作名」和「删掉后的提示」不同（移出书架 / 移出收藏），版式与
/// 交互完全一致，抽在这里避免两份镜像实现慢慢漂移。具体操作由调用方注入
/// （两边写的是不同的存储），删除完成后的提示统一由本方法弹出。
Future<void> showMediaManageSheet({
  required BuildContext context,
  required String title,
  required String removeLabel,
  required VoidCallback openDetail,
  required Future<void> Function() remove,
  required String removedMessage,
}) async {
  final action = await showModalBottomSheet<_ManageAction>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final scheme = theme.colorScheme;
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('查看详情'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_ManageAction.openDetail),
            ),
            ListTile(
              leading: Icon(
                Icons.bookmark_remove_outlined,
                color: scheme.error,
              ),
              title: Text(removeLabel, style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.of(sheetContext).pop(_ManageAction.remove),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _ManageAction.openDetail:
      openDetail();
    case _ManageAction.remove:
      await remove();
      if (!context.mounted) return;
      showAppSnackBar(context, removedMessage);
  }
}
