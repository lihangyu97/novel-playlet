import 'package:flutter/material.dart';

import '../../app/widgets/detail/detail_common.dart';

/// 简介 + 标签卡片（与短剧详情共用 [DetailIntroCard]）。
class DetailIntroSection extends StatelessWidget {
  const DetailIntroSection({
    super.key,
    required this.intro,
    required this.tags,
  });

  final String intro;
  final List<String> tags;

  @override
  Widget build(BuildContext context) =>
      DetailIntroCard(intro: intro, tags: tags);
}
