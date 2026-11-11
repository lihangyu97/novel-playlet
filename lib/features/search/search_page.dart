import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/media_card.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../app/widgets/surface_card.dart';
import '../../app/widgets/top_glow.dart';
import '../feed/feed_search_field.dart';
import '../feed/feed_state.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_item.dart';
import '../video/widgets/video_card.dart';
import 'search_cue_hint.dart';
import 'search_providers.dart';

/// 独立搜索页：一次提交同时搜小说 / 短剧，从上到下各一行横向卡片。
///
/// 不再单列「漫剧」行：上游漫剧搜索并没有独立 tab，是借短剧搜索 tab 再按
/// `genre=205` 过滤出来的，和短剧行本质是同一份响应的两种切片；单列会让
/// 同一部剧出现两次、还把同一个请求打两遍。现在短剧行直接展示这份混排结果
/// （漫剧卡片混在其中，但卡面不再显示「漫剧」标签）。
///
/// 从推荐页顶部搜索框点进来（推荐页的搜索框是只读入口）。搜索词只属于这个
/// 页面（autoDispose），返回后推荐页仍停在原来的推荐流，不会被搜索改写。
///
/// 卡片直接复用首页推荐流的两张卡（[NovelGridCard] / [VideoCard]，白底卡 +
/// 原生封面比例），只按屏宽算一个更窄的卡宽、字号整体缩一档：观感是「首页
/// 同款卡片的小号版」，而不是另做一套搜索条目。一屏露出 3.5 张卡，第 4 张只
/// 露半边，暗示这一行可以往右滑。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialCueWord = ''});

  /// 推荐页搜索框当前轮播到的热词：占位从同一条接着显示，空输入提交时直接
  /// 搜它（没有热词时占位回退静态提示）。
  final String initialCueWord;

  /// 卡片行左右留白与卡片间距：与首页推荐流一致（8）。
  static const double rowPadding = 8;
  static const double cardGap = 8;

  /// 搜索页的分类顺序（只保留有独立搜索链路的两类）。
  ///
  /// 漫剧没有独立搜索 tab（借短剧 tab 过滤），不单列成一行，否则同一份数据
  /// 会被请求两次、两个行里重复出现。
  static const searchCategories = [
    RecommendCategory.novel,
    RecommendCategory.drama,
  ];

  /// 一屏露出的卡片数：3 张完整卡 + 半张，提示「还能往右滑」。
  static const double visibleCards = 3.5;

  /// 屏幕宽度 → 卡宽：3 张完整卡之间 3 个间距，两侧各 [rowPadding]。
  static double cardWidthFor(double maxWidth) =>
      (maxWidth - rowPadding * 2 - cardGap * 3) / visibleCards;

  /// 卡片字号相对首页缩小的比例。
  ///
  /// 卡宽只有首页双列的一半多一点，字号不缩会让标题/元信息显得又大又挤；
  /// 缩一档后标题仍放得下两行，才像「同款卡片的小号版」。
  static const double cardFontScale = 0.88;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// 搜索框当前轮播到的热词（子组件上报，普通字段，不触发重建）。
  String _currentCueWord = '';

  @override
  void initState() {
    super.initState();
    _currentCueWord = widget.initialCueWord;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    var query = raw.trim();
    _focus.unfocus();
    if (query.isEmpty) {
      // 空输入提交：热词只是占位（placeholder），用户没打字时回车/点搜索
      // 就搜当前轮播到的那条；把词填回输入框，让用户看得见实际搜了什么。
      final cue = _currentCueWord.trim();
      if (cue.isEmpty) {
        _clear();
        return;
      }
      query = cue;
      _controller.text = cue;
      _controller.selection = TextSelection.collapsed(offset: cue.length);
    }
    final active = ref.read(searchQueryProvider);
    if (active == query) {
      // 同一关键词再次提交 = 重试：只重拉失败的那几行，正在加载/已有结果的行
      // 不动，避免按一次搜索键把两个请求重复打出去。
      for (final category in SearchPage.searchCategories) {
        final request = SearchRequest(category: category, query: query);
        if (ref.read(searchResultsProvider(request)).hasError) {
          ref.invalidate(searchResultsProvider(request));
        }
      }
      return;
    }
    ref.read(searchQueryProvider.notifier).submit(query);
  }

  /// 清空输入：回到引导空态（两行结果一起消失）。
  void _clear() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).clear();
    _focus.requestFocus();
  }

  /// 取消 / 返回：搜索词随页面 autoDispose 自动清掉，这里只退页——提前清会让
  /// 退出动画期间整页先闪成引导空态。
  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    // 渐变要盖到状态栏那一条（安全区不参与布局），与推荐页同一套观感。
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 96 + topInset,
            child: const TopGlow(spec: kRecommendTopGlow),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    SearchPage.rowPadding,
                    8,
                    SearchPage.rowPadding,
                    4,
                  ),
                  child: FeedSearchField(
                    controller: _controller,
                    focusNode: _focus,
                    hintText: '搜索小说 / 短剧',
                    hint: SearchCueHint(
                      fallback: '搜索小说 / 短剧',
                      initialWord: widget.initialCueWord,
                      onWordChanged: (word) => _currentCueWord = word,
                    ),
                    autofocus: true,
                    showCancel: true,
                    onSubmitted: _submit,
                    onClear: _clear,
                    onCancel: _close,
                  ),
                ),
                Expanded(
                  child: query == null
                      ? const EmptyView(
                          message: '输入关键词，一次搜小说 / 短剧',
                          icon: Icons.search_rounded,
                        )
                      : _SearchResults(query: query),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 小说 / 短剧两行结果从上到下依次排开。
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    // 列表按屏底留白：SafeArea 只护住顶部（底部要让渐变/背景铺到屏幕边），
    // 最后一行必须自己躲开 iOS home indicator，否则会压在条上。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.only(bottom: 24 + bottomInset),
      children: [
        for (final category in SearchPage.searchCategories)
          _SearchSection(category: category, query: query),
      ],
    );
  }
}

/// 单个分类的一行：分类标题 + 横向卡片列表（或加载/失败/空态）。
class _SearchSection extends ConsumerWidget {
  const _SearchSection({required this.category, required this.query});

  final RecommendCategory category;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = SearchRequest(category: category, query: query);
    final async = ref.watch(searchResultsProvider(request));
    final items = async.value?.items ?? const <RecommendItem>[];
    // 封面原生比例：小说 3:4，短剧/漫剧 7:10（骨架卡和真卡同一口径）。
    final coverAspect = category == RecommendCategory.novel
        ? kNovelCoverAspect
        : kVideoCoverAspect;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = SearchPage.cardWidthFor(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SearchPage.rowPadding,
                16,
                SearchPage.rowPadding,
                8,
              ),
              child: Text(
                category.label,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (items.isNotEmpty)
              _CardRow(category: category, items: items, width: width)
            else if (async.isLoading)
              // 两行各自请求：加载中给和真卡同宽同高的色块骨架，先回来的行
              // 直接换成真卡，页面不会出现一行字＋两行字的高低跳变。
              Semantics(
                container: true,
                label: '正在搜索${category.label}',
                child: _SkeletonRow(
                  key: ValueKey('search-skeleton-${category.name}'),
                  width: width,
                  coverAspect: coverAspect,
                ),
              )
            else if (async.hasError)
              _SectionStatus(
                icon: Icons.cloud_off_rounded,
                message: describeFeedError(async.error!),
                onRetry: () => ref.invalidate(searchResultsProvider(request)),
              )
            else
              _SectionStatus(
                icon: Icons.search_off_rounded,
                message: '没有找到相关${category.label}',
              ),
          ],
        );
      },
    );
  }
}

/// 一行的横向卡片列表：左右可滑，行高由最高的那张卡撑开（不同分类封面比例
/// 不同，小说行的卡比短剧行矮一点，属预期）。
class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.category,
    required this.items,
    required this.width,
  });

  final RecommendCategory category;
  final List<RecommendItem> items;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 卡片内部所有字号按同一比例缩一档（不直接改共享卡片组件）：卡片宽度变了
    // 但字号还是首页尺寸会「字挤满卡」。
    final compactTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(
        fontSizeFactor: SearchPage.cardFontScale,
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: SearchPage.rowPadding),
      child: Theme(
        data: compactTheme,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(right: SearchPage.cardGap),
                child: _CompactCard(
                  category: category,
                  item: item,
                  width: width,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果卡：封面 + 标题 + 元信息，复用首页同款卡片。
class _CompactCard extends StatelessWidget {
  const _CompactCard({
    required this.category,
    required this.item,
    required this.width,
  });

  final RecommendCategory category;
  final RecommendItem item;
  final double width;

  /// Hero tag 的来源维度：同一本书可能同时出现在搜索页与推荐页，tag 必须带
  /// 页面与分类，否则两个路由里的 Hero 会撞 tag。
  String get _heroSource => 'search-${category.name}';

  void _open(BuildContext context) {
    switch (item) {
      case NovelRecommendItem(:final novel):
        context.pushAppRoute(
          DetailRoute(
            bookId: novel.id,
            preview: novel,
            heroTag: CoverHeroTag.novel(_heroSource, novel.id),
          ),
        );
      case VideoRecommendItem(:final video):
        context.pushAppRoute(
          VideoDetailRoute(
            seriesId: video.id,
            preview: video,
            heroTag: CoverHeroTag.video(_heroSource, video.id),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    void onTap() => _open(context);
    // 搜索结果里作者 / 集数固定一行，评分走封面右上角角标；理由/热度这类
    // 推荐字段搜索一般没有，有就按首页三列规则各占一行。
    final card = switch (item) {
      NovelRecommendItem(:final novel) => NovelGridCard(
        key: ValueKey('search-novel-${novel.id}'),
        item: novel,
        width: width,
        onTap: onTap,
        heroTag: CoverHeroTag.novel(_heroSource, novel.id),
        showRecommendMeta: true,
        coverAspect: kNovelCoverAspect,
        surface: true,
      ),
      VideoRecommendItem(:final video) => VideoCard(
        key: ValueKey('search-video-${video.id}'),
        item: video,
        width: width,
        onTap: onTap,
        heroTag: CoverHeroTag.video(_heroSource, video.id),
        showRecommendMeta: true,
        // 搜索卡不展示推荐理由：这个字段（`recommend_reason_list` 第一条）在
        // 搜索响应里不是分类名（「漫剧」）就是「上新/热门」这类角标，和卡片上
        // 的集数/热度重复且挤占窄卡；只留「全 N 集 + 热度」。
        showReason: false,
        coverAspect: kVideoCoverAspect,
        surface: true,
      ),
    };
    return card;
  }
}

/// 一行的加载骨架：4 张与真卡同宽同高的色块占位。
///
/// 一屏露出 3.5 张，骨架铺 4 张让第 4 张压在屏幕边上，和真卡行看起来一致；
/// 两行并行请求，哪一行先回来哪一行先换成真卡。
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({
    super.key,
    required this.width,
    required this.coverAspect,
  });

  final double width;
  final double coverAspect;

  static const int _cardCount = 4;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: SearchPage.rowPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _cardCount; i++)
            Padding(
              padding: const EdgeInsets.only(right: SearchPage.cardGap),
              child: _SkeletonCard(width: width, coverAspect: coverAspect),
            ),
        ],
      ),
    );
  }
}

/// 骨架卡：白底卡 + 封面/标题/元信息三处色块。
///
/// 高度口径和真卡（[MediaCard]）一致：封面按内容域原生比例，文字区用同一个
/// 「字号缩一档」后的行高算两行标题 + 一行元信息，换真卡时行高不跳。
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.width, required this.coverAspect});

  final double width;
  final double coverAspect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final compactTextTheme = theme.textTheme.apply(
      fontSizeFactor: SearchPage.cardFontScale,
    );
    final titleLineHeight =
        textScaler.scale(compactTextTheme.bodyMedium?.fontSize ?? 14) *
        MediaCard.titleLineHeightFactor;
    final metaLineHeight =
        textScaler.scale(compactTextTheme.bodySmall?.fontSize ?? 12) *
        (compactTextTheme.bodySmall?.height ?? 1.0);
    // 浅色卡上用很浅的灰；深色卡上用略亮一档，和卡片底色区分开。
    final blockColor = theme.colorScheme.onSurface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.14 : 0.07,
    );

    Widget bar(double barWidth, double barHeight) => Container(
      width: barWidth,
      height: barHeight,
      decoration: BoxDecoration(
        color: blockColor,
        borderRadius: BorderRadius.circular(barHeight / 2),
      ),
    );

    return SizedBox(
      width: width,
      child: AppSurfaceCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              height: width * coverAspect,
              color: blockColor,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题固定两行（与真卡 naturalTitleHeight=false 时一致）。
                  SizedBox(
                    height: titleLineHeight * 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(width * 0.5, titleLineHeight * 0.58),
                        const SizedBox(height: 6),
                        bar(width * 0.35, titleLineHeight * 0.58),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  bar(width * 0.28, metaLineHeight * 0.6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类行里的失败 / 空态：只占一行，不撑出整块空白（加载中走 [_SkeletonRow]）。
class _SectionStatus extends StatelessWidget {
  const _SectionStatus({required this.message, this.icon, this.onRetry});

  final String message;
  final IconData? icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SearchPage.rowPadding,
        2,
        SearchPage.rowPadding,
        2,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
