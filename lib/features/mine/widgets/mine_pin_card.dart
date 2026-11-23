import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/widgets/surface_card.dart';
import '../../../core/storage/library_records.dart';
import '../mine_record_copy.dart';

/// 「在看」区块的单张卡片：只有标题和进度，不放封面。
///
/// 横向一排展示，卡片宽度固定，屏幕上大约露出两张半；内容再多就左右滑，
/// 不折行、不换行，保证「在看」始终只占一行高度。
class MinePinCard extends StatelessWidget {
  const MinePinCard({super.key, required this.item, required this.onTap});

  /// 卡片宽度固定，屏幕上大约露出两张半。
  static const double width = 168;

  /// 基础高度撑起「在看」那一排（标题行 + 弹性留白 + 进度行）。
  ///
  /// 系统字号放大时卡片要跟着长高，否则 Column 会在固定高度里溢出；
  /// 上限定在 140 是给「小屏 + 超大字号」兜底，再高就横滑也放不下了。
  static double heightFor(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final title = theme.textTheme.titleSmall;
    final body = theme.textTheme.bodySmall;
    final titleLine =
        scaler.scale(title?.fontSize ?? 14) * (title?.height ?? 1.4);
    final bodyLine = scaler.scale(body?.fontSize ?? 12) * (body?.height ?? 1.4);
    return (titleLine + bodyLine + 36).clamp(76.0, 140.0).toDouble();
  }

  final LibraryRecord item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 出版社/连载信息不在这里出现：只在看「我在追什么、追到哪」。
    final title = item.title.isEmpty ? '未命名作品' : item.title;
    return SizedBox(
      width: width,
      child: AppSurfaceCard(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.push_pin_rounded, size: 14, color: scheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: context.appWeight(FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                mineHistorySubtitle(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
