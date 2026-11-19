import 'package:flutter/material.dart';

import '../../../core/storage/library_records.dart';

/// 小说标签的底色：亮绿。
const Color kNovelTagColor = Color(0xFF16A34A);

/// 短剧标签的底色：亮橙。
///
/// 两个色都取"亮一档但白字仍可读"的区间：压在小封面上，太浅会被封面吃掉，
/// 太白又和封面撞色。文字统一白字 + 600 字重。
const Color kPlayletTagColor = Color(0xFFEA580C);

/// 历史 / 收藏 / 云端数据里区分「小说 / 短剧」的彩色小标签。
///
/// 视觉上只放一个字（小说→「书」、短剧→「剧」）：小尺寸下更易扫读，窄封面
/// 和列表行里也不抢标题。高度按字号算（不写死），跟随系统字号缩放；圆角 4，
/// 和封面圆角同一套收敛感。读屏仍念全称（见 [semanticsLabel]），单字脱离
/// 上下文不够清楚。
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

  /// 无障碍文案；默认按类型念「小说」/「短剧」（视觉上是单字「书」/「剧」）。
  final String? semanticsLabel;

  String get _label => type.isPlaylet ? '剧' : '书';

  /// 读屏文案：视觉单字缩写，读屏念完整类型。
  String get _semanticsLabel =>
      semanticsLabel ?? (type.isPlaylet ? '短剧' : '小说');

  @override
  Widget build(BuildContext context) {
    final color = type.isPlaylet ? kPlayletTagColor : kNovelTagColor;
    return Semantics(
      label: _semanticsLabel,
      excludeSemantics: true,
      child: Container(
        // 中文墨迹在行盒里天然偏下约 0.5pt：上下内边距做成「上少下多」，
        // 把文字抬回视觉中心。胶囊总高不变（dense 1pt、普通 3pt），不改变
        // 列表行高和封面角标的位置。
        padding: EdgeInsets.only(
          left: dense ? 4 : 5,
          right: dense ? 4 : 5,
          top: dense ? 0 : 1,
          bottom: dense ? 1 : 2,
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
