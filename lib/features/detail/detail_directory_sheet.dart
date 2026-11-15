import 'package:flutter/material.dart';

import '../../app/widgets/app_bottom_sheet.dart';
import '../../app/widgets/chapter_directory_sheet.dart';
import '../../data/models/chapter.dart';

/// 打开全部目录的底部弹层；返回被点中的章节（取消返回 null）。
///
/// 列表本身直接复用阅读器那套 [ChapterDirectorySheet]：右侧常驻可拖动滚动条、
/// 当前章左侧主色竖条 + 「读到这里」、打开时定位到进度所在章；详情页比阅读器
/// 多插一层卷标题。
Future<Chapter?> showDetailDirectorySheet(
  BuildContext context, {
  required List<Chapter> chapters,
  int? currentIndex,
}) {
  return showAppBottomSheet<Chapter>(
    context: context,
    builder: (sheetContext) => ChapterDirectorySheet(
      chapters: chapters,
      currentIndex: currentIndex,
      currentLabel: '读到这里',
      showVolumes: true,
      onSelected: (index) {
        Navigator.of(sheetContext).pop(chapters[index]);
      },
    ),
  );
}
