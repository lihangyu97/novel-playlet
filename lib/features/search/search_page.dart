import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/widgets/compact_card_row.dart';
import '../../app/widgets/cover_hero.dart';
import '../../app/widgets/novel_card.dart';
import '../../app/widgets/novel_cover.dart';
import '../../app/widgets/states.dart';
import '../../app/widgets/top_glow.dart';
import '../../data/models/hot_search.dart';
import '../feed/feed_search_field.dart';
import '../feed/feed_state.dart';
import '../recommend/recommend_category.dart';
import '../recommend/recommend_item.dart';
import '../video/widgets/video_card.dart';
import 'search_cue_hint.dart';
import 'search_history.dart';
import 'search_providers.dart';

/// 独立搜索页：一次提交同时搜小说 / 短剧，从上到下各一行横向卡片。
///
/// 不再单列「漫剧」行：上游漫剧搜索并没有独立 tab，是借短剧搜索 tab 再按
/// `genre=205` 过滤出来的，和短剧行本质是同一份响应的两种切片；单列会让
/// 同一部剧出现两次、还把同一个请求打两遍。现在短剧行直接展示这份混排结果
/// （漫剧卡片混在其中，但卡面不再显示「漫剧」标签）。
///
/// 从推荐页顶栏右侧的搜索图标点进来。搜索词只属于这个页面（autoDispose），
/// 返回后推荐页仍停在原来的推荐流，不会被搜索改写。
///
/// 卡片直接复用首页推荐流的两张卡（[NovelGridCard] / [VideoCard]，白底卡 +
/// 原生封面比例），行内宽度/字号口径统一在 [CompactCardRow]（与首页榜单
/// 预览同一套）：观感是「首页同款卡片的小号版」，而不是另做一套搜索条目。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  /// 搜索页的分类顺序（只保留有独立搜索链路的两类）。
  ///
  /// 漫剧没有独立搜索 tab（借短剧 tab 过滤），不单列成一行，否则同一份数据
  /// 会被请求两次、两个行里重复出现。
  static const searchCategories = [
    RecommendCategory.novel,
    RecommendCategory.drama,
  ];

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// 搜索框当前轮播到的热词（子组件上报，普通字段，不触发重建）。
  String _currentCueWord = '';

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
    // 不管是不是重复提交，都把关键词记进历史（重复项会被提到最前）。
    ref.read(searchHistoryProvider.notifier).add(query);
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

  /// 点历史关键词：填回输入框并立即发起搜索。
  void _searchKeyword(String keyword) {
    final query = keyword.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    _focus.unfocus();
    ref.read(searchHistoryProvider.notifier).add(query);
    ref.read(searchQueryProvider.notifier).submit(query);
  }

  /// 取消 / 返回：搜索词随页面 autoDispose 自动清掉，这里只退页——提前清会让
  /// 退出动画期间整页先闪成引导空态。
  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    // 热搜榜在这里也保持订阅：搜索结果页仍让它在后台加载完，清空输入回到
    // 引导页时立即有榜单，不会先闪一下「输入关键词」空态再跳出来。页面临时
    // 关闭时随 autoDispose 释放，下次进来重新拉一份。
    ref.watch(hotSearchProvider);
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
                  // 顶部不留内边距：搜索框上沿贴住安全区，进页面时不会先
                  // 空一段再落位。
                  padding: const EdgeInsets.fromLTRB(
                    CompactCardRow.rowPadding,
                    0,
                    CompactCardRow.rowPadding,
                    4,
                  ),
                  child: FeedSearchField(
                    controller: _controller,
                    focusNode: _focus,
                    hintText: '搜索小说 / 短剧',
                    hint: SearchCueHint(
                      fallback: '搜索小说 / 短剧',
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
                      ? _SearchLandingView(onSearch: _searchKeyword)
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

/// 搜索引导页：搜索历史在上，热搜榜在下。
///
/// 只展示引导内容（历史 / 热搜），提交关键词后整页换成结果。两者都为空时
/// 才退回引导空态——第一次进来还没有历史，但热搜榜仍然值得展示。
class _SearchLandingView extends ConsumerWidget {
  const _SearchLandingView({required this.onSearch});

  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);
    final hot = ref.watch(hotSearchProvider).value ?? HotSearch.empty;
    if (history.isEmpty && hot.isEmpty) {
      return const EmptyView(
        message: '输入关键词，一次搜小说 / 短剧',
        icon: Icons.search_rounded,
      );
    }
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(8, 12, 8, 24 + bottomInset),
      children: [
        if (history.isNotEmpty)
          _SearchHistorySection(history: history, onSearch: onSearch),
        if (hot.isNotEmpty) ...[
          if (history.isNotEmpty) const SizedBox(height: 24),
          _HotSearchSection(hot: hot, onSearch: onSearch),
        ],
      ],
    );
  }
}

/// 搜索历史：标题 + 清空按钮 + 关键词 pill。
class _SearchHistorySection extends ConsumerWidget {
  const _SearchHistorySection({required this.history, required this.onSearch});

  final List<String> history;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text(
                '搜索历史',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: context.appWeight(FontWeight.w600),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    ref.read(searchHistoryProvider.notifier).clear(),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.onSurfaceVariant,
                  textStyle: theme.textTheme.bodySmall,
                ),
                child: const Text('清空'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final keyword in history)
                _SearchHistoryChip(
                  keyword: keyword,
                  onTap: () => onSearch(keyword),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单个历史关键词：可点的小圆角 pill（与详情页标签同一套观感）。
class _SearchHistoryChip extends StatelessWidget {
  const _SearchHistoryChip({required this.keyword, required this.onTap});

  final String keyword;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(99),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            keyword,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// 热搜榜：标题 + 最多三十条（名次 / 词 / 角标 / 热搜值）。
///
/// 上游一次回 50 条，超过 30 条时只铺前 30：名次 1–3 标红，其余用次级色；
/// 标题后紧跟 `display_tag` 彩色角标（热聊 / 飙升 / 霸榜 …）；右侧保留接口
/// 给的热度前缀（热门讨论 / 热度飙升 / 巅峰榜NO.3 …），只把数字换算成整数
/// `3905w+`。点一条直接按这个词搜索。
class _HotSearchSection extends StatelessWidget {
  const _HotSearchSection({required this.hot, required this.onSearch});

  /// 一次最多渲染的条数：上游一次回 50 条（2026-11-15 实测），超过 30 条
  /// 会明显把搜索历史埋掉，所以只铺前 30；不超过 30 条时全部渲染。
  static const maxRows = 30;

  final HotSearch hot;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final entries = hot.entries.take(maxRows).toList(growable: false);
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text(
            '热搜榜',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: context.appWeight(FontWeight.w600),
            ),
          ),
        ),
        Column(
          key: const Key('search_hot_words'),
          children: [
            for (var index = 0; index < entries.length; index++)
              _HotSearchRow(
                entry: entries[index],
                rank: index + 1,
                onTap: () => onSearch(entries[index].title),
              ),
          ],
        ),
      ],
    );
  }
}

/// 热搜榜一行：名次（前三红）+ 词 + 右侧热搜值。
class _HotSearchRow extends StatelessWidget {
  const _HotSearchRow({
    required this.entry,
    required this.rank,
    required this.onTap,
  });

  final HotSearchEntry entry;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = rank <= 3;
    final hotLabel = entry.hotLabel;
    final badge = entry.badge;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('search_hot_${entry.title}'),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '$rank',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: top ? scheme.error : scheme.onSurfaceVariant,
                      fontSize: top ? 15 : 13,
                      height: 1.2,
                      fontWeight: top
                          ? context.appWeight(FontWeight.w700)
                          : context.appWeight(FontWeight.w500),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  // 标题和角标放同一个 Row：标题按自身宽度收缩，角标紧跟标题，
                  // 不用 Expanded 把角标推到右边；剩余空白留在角标之后，右侧
                  // 热度列仍然贴边对齐。
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface,
                            fontSize: 14,
                            height: 1.3,
                            fontWeight: top
                                ? context.appWeight(FontWeight.w600)
                                : context.appWeight(FontWeight.w400),
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 4),
                        _HotBadge(
                          key: ValueKey('search_hot_badge_${entry.title}'),
                          badge: badge,
                        ),
                      ],
                    ],
                  ),
                ),
                if (hotLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    hotLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      height: 1.2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 热搜角标：文字 + 上游给的明暗两套颜色（`display_tag`）。
///
/// 位置紧跟标题文字（4pt 间距）：角标是「热聊 / 飙升 / 霸榜」这类短标签，
/// 贴着标题读起来像一个整体，比放到最左边更不抢名次，也不会和右侧热度列
/// 混成一片。上游没给颜色时用主题的浅色底兜底，深色模式取 dark 一套。
class _HotBadge extends StatelessWidget {
  const _HotBadge({super.key, required this.badge});

  final HotSearchBadge badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 上游的 light/dark 文本色是「亮橙 / 暗橙」：浅色底上用暗的一档、深色底上
    // 用亮的一档才有对比度，所以文本色取背景色的相反一套；背景色仍按明暗取。
    final preferredText = dark ? badge.lightTextColors : badge.darkTextColors;
    final fallbackText = dark ? badge.darkTextColors : badge.lightTextColors;
    final textColors = preferredText.isNotEmpty ? preferredText : fallbackText;
    final backgroundColors = dark
        ? badge.darkBackgroundColors
        : badge.lightBackgroundColors;
    final textColor = textColors.isEmpty
        ? scheme.onSurfaceVariant
        : Color(textColors.first);

    final BoxDecoration decoration;
    if (backgroundColors.isEmpty) {
      decoration = BoxDecoration(
        color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(4),
      );
    } else if (backgroundColors.length == 1) {
      decoration = BoxDecoration(
        color: Color(backgroundColors.first),
        borderRadius: BorderRadius.circular(4),
      );
    } else {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          colors: [for (final color in backgroundColors) Color(color)],
        ),
        borderRadius: BorderRadius.circular(4),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 48),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: decoration,
      child: Text(
        badge.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          height: 1.2,
          fontWeight: context.appWeight(FontWeight.w600),
        ),
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
        final width = CompactCardRow.cardWidthFor(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CompactCardRow.rowPadding,
                16,
                CompactCardRow.rowPadding,
                8,
              ),
              child: Text(
                category.label,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: context.appWeight(FontWeight.w600)),
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
                child: CompactSkeletonRow(
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
    return CompactCardRow(
      children: [
        for (final item in items)
          _CompactCard(category: category, item: item, width: width),
      ],
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

/// 分类行里的失败 / 空态：只占一行，不撑出整块空白（加载中走 [CompactSkeletonRow]）。
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
        CompactCardRow.rowPadding,
        2,
        CompactCardRow.rowPadding,
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
