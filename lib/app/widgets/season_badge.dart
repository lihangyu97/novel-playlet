import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 短剧封面左下角的「第 N 季」角标。
///
/// 季只存在于标题文字里，而卡片标题两行省略时尾部的季正好被吃掉（见
/// `core/season_title.dart`）；角标把它拎到封面上，同一系列的第二、四、七季
/// 一眼可分。
///
/// 放左下而不是底部居中：上游海报把剧名/季印在底部正中——漫剧是金色艺术字
/// 加装饰线，真人剧那里是主角脸部特写——压上去要么和自带的季字重影、要么
/// 挡脸。左下方在三个入口都不与既有角标冲突（搜索页左上为空、推荐双列左上
/// 是推荐理由、收藏左上角是类型标签），并且和右上角评分形成对角。
///
/// 底色走主题主色、跟着设置里的主题色一起变：与右上角评分的深色胶囊区分开，
/// 又不硬编码颜色。
class SeasonBadge extends StatelessWidget {
  const SeasonBadge({super.key, required this.season});

  final int season;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = '第$season季';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onPrimary,
            fontSize: 10,
            height: 1.15,
            fontWeight: context.appWeight(FontWeight.w600),
          ),
        ),
      ),
    );
  }
}
