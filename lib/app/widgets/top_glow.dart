import 'package:flutter/material.dart';

/// 顶部固定模块的「蓝 → 粉」氛围渐变。
///
/// 只是一点点氛围：低透明度、纯装饰、不承载任何信息（不参与语义与点击）。
/// 推荐页（搜索栏）与我的页（页头 + tabs）各用一套**略微不同**的角度与色标，
/// 避免两页看到一模一样的色带；我的页整页共用一套，不随小说/短剧 tab 切换。
@immutable
class TopGlowSpec {
  const TopGlowSpec({
    required this.begin,
    required this.end,
    required this.stops,
  });

  final Alignment begin;
  final Alignment end;

  /// 蓝 → 紫 → 粉三档的色标位置，两处略微不同。
  final List<double> stops;

  LinearGradient gradient(Color blue, Color mid, Color pink) => LinearGradient(
    begin: begin,
    end: end,
    colors: [blue, mid, pink],
    stops: stops,
  );
}

/// 推荐页顶部（搜索框 + 分类 tabs）：接近水平、略微下斜。
const kRecommendTopGlow = TopGlowSpec(
  begin: Alignment(-1, -0.25),
  end: Alignment(1, 0.45),
  stops: [0.0, 0.5, 1.0],
);

/// 我的页（页头 + 小说/短剧 tabs）：略微上斜，与推荐页形成一点差异。
///
/// 小说/短剧两个 tab 共用这一套：页头是统一的，渐变不该跟着 tab 变。
const kMineTopGlow = TopGlowSpec(
  begin: Alignment(-1, 0.35),
  end: Alignment(1, -0.2),
  stops: [0.0, 0.55, 1.0],
);

/// 顶部装饰渐变层：横向蓝 → 粉，向下淡出，固定不滚动。
///
/// 用 [ShaderMask] 做竖向淡出，避免固定模块底部出现一条生硬的色带边缘。
class TopGlow extends StatelessWidget {
  const TopGlow({super.key, required this.spec});

  final TopGlowSpec spec;

  /// 固定色相（不跟主题 seed 走）：换主题色时这条氛围保持"蓝粉"意图。
  static const Color _blue = Color(0xFF4C8DFF);
  static const Color _mid = Color(0xFFA78BFA);
  static const Color _pink = Color(0xFFFF7EB6);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 深色底上同样的色带需要略高一点不透明度才看得见，仍然保持"一点点"。
    final alpha = dark ? 0.16 : 0.10;
    Color tint(Color color) => color.withValues(alpha: alpha);
    return IgnorePointer(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Color(0x00FFFFFF)],
          stops: [0.0, 0.35, 1.0],
        ).createShader(bounds),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: spec.gradient(tint(_blue), tint(_mid), tint(_pink)),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
