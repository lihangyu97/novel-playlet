import 'package:flutter/material.dart';

import '../../../core/storage/library_records.dart';

/// 小说标签的底色：亮绿。
const Color kNovelTagColor = Color(0xFF16A34A);

/// 短剧标签的底色：亮橙。
///
/// 两个色都取"亮一档但白字仍可读"的区间：压在小封面上，太浅会被封面吃掉，
/// 太白又和封面撞色。文字统一白字 + 600 字重。
const Color kPlayletTagColor = Color(0xFFEA580C);

/// 历史 / 收藏里区分「小说 / 短剧」的彩色小标签。
///
/// 高度按字号算（不写死），跟随系统字号缩放；圆角 4，和封面圆角同一套收敛感。
class LibraryTypeBadge extends StatelessWidget {
  const LibraryTypeBadge({
    super.key,
    required this.type,
    this.dense = false,
    this.semanticsLabel,
  });

  final LibraryType type;

  /// 紧凑形态：历史列表的副标题行用，字号与内边距都小一档。
  final bool dense;

  /// 无障碍文案；默认「小说」/「短剧」。
  final String? semanticsLabel;

  String get _label => type.isPlaylet ? '短剧' : '小说';

  @override
  Widget build(BuildContext context) {
    final color = type.isPlaylet ? kPlayletTagColor : kNovelTagColor;
    return Semantics(
      label: semanticsLabel ?? _label,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 4 : 5,
          vertical: dense ? 0.5 : 1.5,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _label,
          style: TextStyle(
            color: Colors.white,
            fontSize: dense ? 9 : 10,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
