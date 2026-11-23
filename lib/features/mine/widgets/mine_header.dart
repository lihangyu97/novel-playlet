import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// 我的页页头：图标 + 主标题 + 缓存 / 设置入口。
///
/// 页头固定贴顶、不随内容滚动；右上角固定两枚图标按钮：缓存中心（离线下载
/// 的书 / 短剧）在左、设置在右，两者同一套线性图标、同尺寸、同颜色。
///
/// 标题下面不再放「历史 x · 收藏 x」的合并统计：两个区块头已经各自显示
/// 条数，统计行属于重复信息，去掉后页头更紧凑。
class MineHeader extends StatelessWidget {
  const MineHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.onCache,
    required this.onSettings,
  });

  final String title;
  final IconData icon;

  /// 缓存中心入口（与设置同一套线性图标，位置在设置左边）。
  final VoidCallback onCache;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      // 顶部不留额外间距：内容直接贴住安全区（与推荐页搜索框一致）。
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 19, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: context.appWeight(FontWeight.w700),
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          // 缓存中心入口挪到这里：推荐页顶栏收成「tabs + 搜索图标」后，
          // 缓存不再有顶部入口，跟设置并排最容易被找到。
          IconButton(
            onPressed: onCache,
            tooltip: '缓存',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            onPressed: onSettings,
            tooltip: '设置',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }
}
