import 'dart:convert';

import 'json_utils.dart';
import 'novel_item.dart';
import 'video_series.dart';

/// 榜单目录里的一档榜（二级 tab）。
///
/// 首页榜单卡片的 `rank_with_category_data.rank_algo_list` 给出榜单名与
/// `rank_algo`；短剧/漫剧榜还要靠上游的 `genre_tab` 分组才能拿到剧集数据：
/// 小说 2 / 短剧 4 / 漫剧 5。这个映射来自同一份响应里的 `cell_selector`
/// （外层「小说 / 出版 / 短剧 / 漫剧 / 听书 / 短篇」），不是猜的。
class RankTab {
  const RankTab({required this.name, required this.algo});

  final String name;

  /// 上游 `rank_algo`，请求时作为 `algo_type`。
  final int algo;

  /// 上游 `genre_tab`：小说 2、短剧 4、漫剧 5。
  int get genreTab {
    if (name.contains('短剧')) return 4;
    if (name.contains('漫剧')) return 5;
    return 2;
  }

  bool get isEmpty => name.isEmpty || algo < 0;
}

/// 一份榜单目录：榜单列表 id + 所有二级 tab。
class RankCatalog {
  const RankCatalog({this.rankId = '', this.tabs = const [], this.alias = ''});

  static const empty = RankCatalog();

  /// 榜单列表 id，来自首页榜单卡片的 `cell_id_str`；请求 entries 时必须带上，
  /// 用占位值上游会静默返回空列表。
  final String rankId;

  final List<RankTab> tabs;

  /// 卡片副标题，如「根据实时阅读热度排行」；可用作页面说明。
  final String alias;

  bool get isEmpty => rankId.isEmpty || tabs.isEmpty;

  RankTab? tabForAlgo(int algo) {
    for (final tab in tabs) {
      if (tab.algo == algo) return tab;
    }
    return null;
  }

  RankTab? tabForGenreTab(int genreTab) {
    for (final tab in tabs) {
      if (tab.genreTab == genreTab) return tab;
    }
    return null;
  }

  /// 从小说首页 payload 里找榜单卡片。
  ///
  /// 目录不是独立接口：它藏在首页某个 cell 的 `rank_with_category_data` 里，
  /// 卡片可能嵌套在任意层，所以递归找第一个带该字段的 map。
  static RankCatalog fromHomepagePayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && asInt(code, -1) != 0 && asInt(code, -1) != 200) {
      return empty;
    }
    final card = _findRankCard(payload);
    if (card == null) return empty;
    final data = asMap(card['rank_with_category_data']);
    if (data == null) return empty;

    final tabs = <RankTab>[];
    final seen = <int>{};
    for (final raw in asList(data['rank_algo_list'])) {
      final map = asMap(raw);
      if (map == null) continue;
      final name = asString(map['rank_name']).trim();
      final algo = asInt(map['rank_algo'], -1);
      if (name.isEmpty || algo < 0 || !seen.add(algo)) continue;
      tabs.add(RankTab(name: name, algo: algo));
    }

    final rankId = firstString(card, ['cell_id_str', 'cell_id']);
    if (rankId.isEmpty && tabs.isEmpty) return empty;
    return RankCatalog(
      rankId: rankId,
      tabs: List.unmodifiable(tabs),
      alias: asString(card['cell_alias']).trim(),
    );
  }

  static Map<String, dynamic>? _findRankCard(dynamic node, [int depth = 0]) {
    if (depth > 12 || node == null) return null;
    if (node is List) {
      for (final child in node) {
        final found = _findRankCard(child, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is! Map) return null;
    final map = Map<String, dynamic>.from(node);
    if (map['rank_with_category_data'] is Map) return map;
    for (final value in map.values) {
      final found = _findRankCard(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
}

/// 榜单里的一条作品。
///
/// 小说榜返回 `book_data`（书籍字段）；短剧榜/漫剧榜带 `genre_tab=4/5` 后
/// 返回 `video_data`（系列字段），两边字段名完全不同，这里统一成一个条目，
/// 由 [kind] 决定点进哪个详情页。
class RankEntry {
  const RankEntry({
    required this.position,
    required this.kind,
    required this.id,
    required this.title,
    this.cover = '',
    this.author = '',
    this.abstract = '',
    this.category = '',
    this.score = '',
    this.heat = '',
    this.episodeCount = 0,
    this.wordNumber = 0,
    this.creationStatus = -1,
    this.colorDominate = '',
    this.tags = const [],
  });

  /// 1-based 名次。
  final int position;

  /// `book` / `video` / `manju`。
  final String kind;

  final String id;
  final String title;
  final String cover;
  final String author;
  final String abstract;
  final String category;
  final String score;

  /// 热度原文，如 `8869万热度` / `6612万热度`。
  final String heat;

  /// 短剧/漫剧的集数。
  final int episodeCount;

  final int wordNumber;
  final int creationStatus;
  final String colorDominate;

  /// 题材标签（已去掉 [category] 那一项，避免和元信息重复）。
  final List<String> tags;

  bool get isEmpty => id.isEmpty && title.isEmpty;
  bool get isVideo => kind == 'video' || kind == 'manju';
  bool get isManju => kind == 'manju';

  String get scoreLabel => score.isEmpty ? '' : '$score分';

  String get statusLabel => switch (creationStatus) {
    0 => '完结',
    1 => '连载中',
    4 => '停更',
    _ => '',
  };

  /// 列表第二行：小说「作者 · 分类 · 热度」，短剧/漫剧「分类 · 全 N 集 · 热度」。
  String get metaLabel {
    final parts = <String>[
      if (!isVideo && author.isNotEmpty) author,
      if (category.isNotEmpty) category,
      if (isVideo && episodeCount > 0) '全$episodeCount集',
      if (!isVideo && statusLabel.isNotEmpty && author.isEmpty) statusLabel,
      if (heat.isNotEmpty) heat,
    ];
    return parts.join(' · ');
  }

  NovelItem toNovelItem() => NovelItem(
    id: id,
    title: title,
    cover: cover,
    author: author,
    intro: abstract,
    category: category,
    wordCount: wordNumber,
    score: score,
    rankScore: heat,
    colorDominate: colorDominate,
  );

  VideoSeries toVideoSeries() => VideoSeries(
    id: id,
    title: title,
    cover: cover,
    intro: abstract,
    episodeCount: episodeCount,
    isManju: isManju,
    score: score,
    rankScore: heat,
    colorDominate: colorDominate,
  );
}

/// 一页榜单。
class RankBoard {
  const RankBoard({
    this.entries = const [],
    this.hasMore = false,
    this.nextOffset,
    this.alias = '',
  });

  static const empty = RankBoard();

  final List<RankEntry> entries;
  final bool hasMore;

  /// 下一页 offset；null = 没有下一页。
  final int? nextOffset;

  /// 当前榜的说明文案（上游 `cell_alias`）。
  final String alias;

  bool get isEmpty => entries.isEmpty;

  /// 解析 `/api/v1/rank/{rankId}` 的响应。
  ///
  /// [genreTab] 决定视频条目算短剧还是漫剧；[offset] 是本次请求的 offset，
  /// 用于上游不给 `next_offset` 时按本页条数推进；[startAt] 是首条名次。
  static RankBoard fromPayload(
    Map<String, dynamic> payload, {
    required int genreTab,
    int offset = 0,
    int startAt = 1,
  }) {
    final code = payload['code'];
    if (code != null && asInt(code, -1) != 0 && asInt(code, -1) != 200) {
      return empty;
    }
    final data = asMap(payload['data']);
    if (data == null) return empty;
    final cellView = asMap(data['cell_view']);
    if (cellView == null) return empty;
    final cells = asList(cellView['cell_data']);

    final entries = <RankEntry>[];
    final seen = <String>{};

    void addBook(Map<String, dynamic> book) {
      final entry = _bookEntry(book, startAt + entries.length);
      if (entry == null) return;
      final key = entry.id.isEmpty ? 't:${entry.title}' : entry.id;
      if (!seen.add(key)) return;
      entries.add(entry);
    }

    void addVideo(Map<String, dynamic> video) {
      final entry = _videoEntry(
        video,
        startAt + entries.length,
        isManju: genreTab == 5,
      );
      if (entry == null) return;
      final key = entry.id.isEmpty ? 't:${entry.title}' : entry.id;
      if (!seen.add(key)) return;
      entries.add(entry);
    }

    void addCell(Map<dynamic, dynamic> cell) {
      final book = _firstBook(cell);
      if (book != null) {
        addBook(book);
        return;
      }
      final video = _firstVideo(cell);
      if (video != null) {
        addVideo(video);
        return;
      }
      // 少数榜把作品包在 group cell 的 cell_data 里；只下钻一层，避免把
      // 推荐流里的嵌套区块误当榜单。
      for (final nested in asList(cell['cell_data'])) {
        final sub = asMap(nested);
        if (sub != null) addCell(sub);
      }
    }

    for (final cell in cells) {
      final map = asMap(cell);
      if (map != null) addCell(map);
    }

    final hasMore = data['has_more'] == true;
    final upstreamNext = asInt(data['next_offset']);
    final nextOffset = upstreamNext > offset
        ? upstreamNext
        : (hasMore && entries.isNotEmpty ? offset + entries.length : null);

    return RankBoard(
      entries: List.unmodifiable(entries),
      hasMore: hasMore,
      nextOffset: nextOffset,
      alias: asString(cellView['cell_alias']).trim(),
    );
  }

  /// 榜单 cell 把书放在 `book_data`（列表或对象）；少数直接挂字段。
  static Map<String, dynamic>? _firstBook(Map<dynamic, dynamic> cell) {
    final raw = cell['book_data'];
    if (raw is List) {
      for (final item in raw) {
        final map = asMap(item);
        if (map != null && map.isNotEmpty) return map;
      }
    } else if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (cell['book_name'] != null || cell['book_id'] != null) {
      return Map<String, dynamic>.from(cell);
    }
    return null;
  }

  static Map<String, dynamic>? _firstVideo(Map<dynamic, dynamic> cell) {
    final raw = cell['video_data'];
    if (raw is List) {
      for (final item in raw) {
        final map = asMap(item);
        if (map != null && map.isNotEmpty) return map;
      }
    } else if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    for (final key in const ['series_id', 'series_id_str', 'video_id']) {
      final value = cell[key];
      if (value != null &&
          '$value'.trim().isNotEmpty &&
          cell['title'] != null) {
        return Map<String, dynamic>.from(cell);
      }
    }
    return null;
  }

  static RankEntry? _bookEntry(Map<String, dynamic> book, int position) {
    final id = firstString(book, ['book_id', 'item_id', 'id']);
    final title = firstString(book, ['book_name', 'title', 'name']);
    if (id.isEmpty && title.isEmpty) return null;

    final categoryTags = _splitTags(book['pure_category_tags']);
    final schemaNames = _schemaNames(book['category_schema']);
    final category = categoryTags.isNotEmpty
        ? categoryTags.first
        : (schemaNames.isNotEmpty
              ? schemaNames.first
              : firstString(book, ['category', 'category_name']));
    final tags = <String>[
      ...categoryTags.skip(1),
      ...schemaNames.where((name) => name != category),
    ];

    return RankEntry(
      position: position,
      kind: 'book',
      id: id,
      title: title,
      cover: firstString(book, coverKeys),
      author: firstString(book, ['author', 'author_name']),
      abstract: firstString(book, [
        'abstract',
        'book_abstract_v2',
        'intro',
        'description',
      ]),
      category: category,
      score: asString(book['score']),
      heat: firstString(book, ['rank_score', 'read_cnt_text']),
      wordNumber: asInt(book['word_number']),
      creationStatus: asInt(book['creation_status'], -1),
      colorDominate: firstString(book, coverColorKeys),
      tags: _dedupe(tags),
    );
  }

  static RankEntry? _videoEntry(
    Map<String, dynamic> video,
    int position, {
    required bool isManju,
  }) {
    final id = firstString(video, [
      'series_id',
      'series_id_str',
      'video_id',
      'book_id',
      'id',
    ]);
    final title = firstString(video, [
      'title',
      'series_title',
      'book_name',
      'name',
    ]);
    if (id.isEmpty && title.isEmpty) return null;

    final secondary = asList(video['secondary_info_list'])
        .map(asMap)
        .whereType<Map<String, dynamic>>()
        .toList();
    String secondaryOf(int type) {
      for (final item in secondary) {
        if (asInt(item['data_type']) == type) {
          final text = asString(item['content']).trim();
          if (text.isNotEmpty) return text;
        }
      }
      return '';
    }

    final schemaNames = _schemaNames(video['category_schema']);
    final category = secondaryOf(3).ifEmpty(
      schemaNames.isNotEmpty
          ? schemaNames.first
          : firstString(video, ['category', 'category_name']),
    );
    final heat = secondaryOf(2)
        .ifEmpty(firstString(video, ['rec_text', 'rank_score']));
    final tags = _dedupe(
      schemaNames.where((name) => name != category).toList(),
    );

    return RankEntry(
      position: position,
      kind: isManju ? 'manju' : 'video',
      id: id,
      title: title,
      cover: firstString(video, ['cover', 'series_cover', ...coverKeys]),
      abstract: firstString(video, [
        'video_desc',
        'series_intro',
        'intro',
        'abstract',
      ]),
      category: category,
      score: asString(video['score']),
      heat: heat,
      episodeCount: asInt(video['episode_cnt']),
      colorDominate: firstString(video, coverColorKeys),
      tags: tags,
    );
  }

  static List<String> _splitTags(Object? raw) {
    final text = asString(raw);
    if (text.isEmpty) return const [];
    return text
        .split(RegExp('[,，]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _schemaNames(Object? raw) {
    dynamic decoded = raw;
    if (raw is String && raw.trim().startsWith('[')) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    final names = <String>[];
    for (final item in asList(decoded)) {
      final map = asMap(item);
      if (map == null) continue;
      final name = asString(map['name']).trim();
      if (name.isNotEmpty) names.add(name);
    }
    return names;
  }

  static List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      final text = value.trim();
      if (text.isEmpty || !seen.add(text)) continue;
      out.add(text);
    }
    return List.unmodifiable(out);
  }
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
