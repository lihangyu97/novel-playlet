import 'package:flutter/material.dart';

import 'app_bottom_sheet.dart';

/// 以底部弹层打开「详情」（阅读页 / 播放页的工具栏入口共用）。
///
/// 只负责弹层外观：0.72 屏高（比目录弹层略矮）、不画标题区与关闭叉号（详情页
/// 自带封面头，右上角浮一个关闭按钮），内容按圆角裁切。打开前后的暂停/恢复
/// 播放、隐藏控制条等由调用方自己处理。
Future<void> showEmbeddedDetailSheet({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showAppBottomSheet<void>(
    context: context,
    builder: (sheetContext) => AppBottomSheet(
      heightFactor: 0.72,
      showClose: false,
      child: builder(sheetContext),
    ),
  );
}
