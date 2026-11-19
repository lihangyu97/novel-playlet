# novel-playlet 开发契约（页面开发必读）

## 现在什么已经就绪

- Flutter 工程（iOS 优先，Android 打包链路已通；不要改 `ios/`；`pubspec.yaml` 依赖受控新增，见硬性规则 2，视频域专项例外见 [docs/implementation.md](docs/implementation.md) 与 `third_party/README.md`）
- Rust 内核 `rust/` 已完整拷入，FRB 绑定在 `lib/src/rust/`（**自动生成，不要手改**）
- 启动链：`lib/main.dart → BootstrapGate → BackendService.start() → Rust init`
- 业务接口：`lib/data/api/api_client.dart`（已封装 recommend / search / hotSearch / rankCatalog / rankBoard / videoFeed / searchVideos / bookDetail / videoDetail / videoEpisodes / videoSource / cachedVideoUrl / directory / chapter / chaptersBatch）
- 模型：`lib/data/models/`（`NovelItem`、`BookDetail`、`Chapter`、`ChapterContent`、`FeedPage`、`VideoSeries`、`VideoDetail`、`VideoSource`、`SearchCue`（搜索框轮播热词）、`HotSearch`（空搜索页热搜榜；`HotSearchEntry.hotPrefix` 保留接口前缀，`hotLabel` 输出 `热门讨论·3905w+` 这种整数 w+；`HotSearchBadge` 保留 `display_tag` 的文字和明暗颜色）、`RankCatalog` / `RankTab` / `RankBoard` / `RankEntry`（排行榜目录与条目，小说 `book_data` / 短剧漫剧 `video_data` 统一成 `RankEntry`）、`json_utils`（含 `ApiErrorKind`））。卡片解析不在 model 层：统一在 `lib/data/parsers/`（`card_walker.dart` 的 `walkCards` / `CardAdapter` 骨架 + `novel_parsers.dart` / `video_parsers.dart`）
- 分类策略：`lib/features/recommend/content_source.dart` 的 `ContentSource`（`NovelSource` / `DramaSource` / `ManjuSource`）。上游 `tab_type`、搜索 tab、漫剧搜索兜底都在策略对象里；`lib/features/recommend/recommend_category.dart` 只留 label / emptyIcon / source，页面不再按分类写 if
- 首页预热：`lib/features/prefetch/app_prefetch.dart` + `lib/features/rank/rank_cache.dart`。推荐页首屏就绪后 400ms 并行预热热搜（`hotSearchProvider`，10min TTL）、短剧/漫剧推荐首屏（`recommendFeedProvider`）与小说/短剧/漫剧三个内容域各自第一顺位榜的首屏（`RankBoardCache`，5min TTL）；只缓存数据、不保活页面。排行榜目录从首页 recommend payload 解析进 `RankCatalogCache`，不再重复请求首页。
- 诊断日志：`lib/core/diagnostics/diagnostic_log.dart`（运行日志存储 `<AppSupport>/app-log.json`，最近 300 条，同一摘要 8s 内合并计数；`error` = 明确报错、`unexpected` = 不符合预期/已兜底恢复）；全局错误捕获 `lib/core/diagnostics/error_handlers.dart`（`FlutterError.onError` + `PlatformDispatcher.onError`，只记录、不改变原处理）；`ApiClient._getJson` 统一记录请求失败与非 JSON/非信封响应，页面在 `lib/features/logs/app_log_page.dart`，入口「设置 → 诊断 → 运行日志」。日志只在本机，不进 `library.db`、不进同步载荷
- 设置云同步：`lib/features/sync/settings_sync_{snapshot,meta,sections,service,coordinator}.dart`。独立 `novel-playlet/<profile>/settings.json`（`v: 1`，与 `sync.json` 解耦），同步主题 / 全局字重 / 推荐布局 / 阅读排版 10 项；倍速与缓存质量不同步。枚举存 name，未知 `v` 停止同步不覆盖；整包 LWW（本地 `settings_local_updated_at_v1` vs 云端 `updatedAt`），推送带 `If-Match`，412 重读重判。阅读页 / 播放页 / 设置页压栈时不 apply（`ImmersivePageTracker`），下次 resumed 重试。设置同步记录也进「同步记录」页（`SyncLogRun.scope = settings`），手动「立即同步」并行跑书架 + 设置。
- 本地存储：`lib/core/storage/reading_store.dart`（书架、阅读进度、最近阅读、短剧收藏/观看进度）；阅读进度表按最近 200 本做 LRU 上限（`progressLimit`）。缓存：`lib/core/cache/`（封面缓存 `AppImageCache`、占用统计与清理 `AppCache`，入口在「我的 → 设置 → 存储」）
- 离线缓存：`lib/core/storage/offline/`（小说/短剧两个 pinned 区的 manifest 与原子读写）+ `lib/features/cache/`（单任务下载器、等待队列、任务持久化、providers、详情底栏三态按钮、缓存中心）。缓存中心同时负责浏览、暂停/继续/重试、删除/清空；设置页不再有离线入口。与自动缓存物理隔离、只手动清理，见下文「离线缓存」
- 主题：`lib/app/theme/app_theme.dart`（Material 3 seed 主题 + `AppAccent` 扩展 + `ReaderPaper` 阅读底色 + 媒体卡圆角/底色 `mediaCardRadius` / `mediaCardColor`）；主题色偏好：`lib/app/theme/theme_settings.dart`（`themeSeedProvider`、`themeModeProvider`，持久化在 `shared_preferences`）。页面颜色一律走 `Theme.of(context).colorScheme`（M3 保证对比度），不要引用 `AppTheme.accent` 常量；只有「需要原始 seed 再自己派生 scheme」的场景（如阅读页按纸色明暗重建主题）才用 `AppTheme.accentOf(context)` + `AppTheme.schemeFor(seed, brightness)`
- 共享组件：`lib/app/widgets/`（`NovelCover`、`AppSurfaceCard`（通用白底卡容器：纯白底 / 暗色 surfaceContainerHigh + 小圆角 + 点击反馈；水波纹在封面图下层、实际只在文字区可见，后续列表逐步卡片化时复用它）、`MediaCard`（列表卡共用骨架：封面 + 标题 + 元信息；`surface` 开白底卡、`naturalTitleHeight` 开标题自然高度、`coverAspect` 换封面比例）、`NovelGridCard` / `VideoCard`（把模型映射成卡片文案的薄适配）、`CategoryTabBar`（一级分类 tabs 通用样式：高度固定 32、默认左对齐（首个 tab 文字左边缘与内容留白 8pt 对齐，槽位按选中态加粗预留宽度，字重变化不挪左边缘）；选中/未选中**字号一致（15）**，高亮只靠颜色 + 字重 + 下划线；当前 tab 文字正下方有一条**与文字等宽的主色短下划线**（高 3、圆角，距文字 2pt），下划线**贴在整行底边**，所以「页头 → tabs」与「下划线 → 内容」两段留白都交给调用方，可以做成等宽；下划线是一条**跟着 `TabController.animation` 滑动的线**（点 tab 时滑过去并顺带改宽度，拖内容区时跟手指走），文字颜色/字重同时连续插值（`TextStyle.lerp`），只有无障碍 `selected` 在过半时切换；传 `center: true` 时整组居中（推荐页用），tab 间距规则不变）、`AppSectionHeader`（区块标题：`title` + 可选 `trailing`/`hint`，标题统一 titleMedium+w600、单行省略，留白由调用方传；简介/书评/目录/选集/最近阅读/设置分区/搜索结果共用）、`SettingSwitchRow`（设置开关行：标题+说明+Switch，阅读弹层按纸色传 `foreground`/`muted`）、`CommentRow`（评论行：头像/昵称/作者标/评分/时间/表情正文/配图/点赞/回复，列表弹层与详情书评卡片共用）、`showEmbeddedDetailSheet`（阅读页/播放页「详情」弹层：0.72 屏高、无标题区/关闭叉号）、`ChapterDirectorySheet`（章节目录弹层：固定行高、打开定位当前章、当前章左侧主色竖条 + 「当前/读到这里」、右侧常驻可拖动滚动条，`showVolumes` 控制卷标题；阅读器「目录」与小说详情「查看全部」共用）、`AppPill`（小标签：胶囊圆角 + surfaceContainerHighest + bodySmall，传 `onTap` 才可点；详情题材标签/搜索历史/榜单条目标签共用）、`ColorSwatchDot`（圆形色块：选中描边+打勾、可传图标/未选中细边/读屏文案；主题预设色、自定义色、阅读底色、取色器预览共用）、`SkeletonBar` / `SkeletonBox`（骨架屏色块，`skeletonBlockColor` 统一明暗系数）、`InlineErrorRow`（行内失败+重试+可选关闭，搜索结果/翻页失败/阅读页切章提示共用）、`KeepAliveBox`（PageView/TabBarView 保活壳）、`gridCellWidth`（`(可用宽 - 间距×(列-1))/列`，我的页与瀑布流共用）、`LoadingView`、`ErrorView`、`EmptyView`）。`lib/core/relative_time.dart` 的 `relativeTime()` 是全 App 唯一的相对时间文案（我的页/评论/回复共用）。短剧选集按钮 `EpisodeTile`（详情内嵌选集与播放页选集弹层共用：无描边、未选中淡底色、选中主色实心）在 `lib/features/video/widgets/`。我的页通用块在 `lib/features/mine/widgets/`（`ShelfGrid<T>`、`RecentList<T>`、`MineTabBody`、`mineTabSection<T>()`（加载/失败占位 + 区块标题 + 网格的标准装配）、`mineRecentSection()`（最近块 + 140 高空态，两个 tab 同一规则））。榜单条目行 `RankEntryRow`（排行榜页列表）与 `rankEntryRoute()`/`openRankEntry()`（排行榜页与首页榜单卡片共用跳转）在 `lib/features/rank/`；首页榜单预览行与搜索结果行共用 `CompactCardRow` / `CompactSkeletonRow`（一屏 3.5 张、字号缩一档、卡宽/间距同一套口径）。小说/短剧两侧只注入数据与文案，不要各写一套短剧选集按钮 `EpisodeTile`（详情内嵌选集与播放页选集弹层共用：无描边、未选中淡底色、选中主色实心）在 `lib/features/video/widgets/`。我的页通用块在 `lib/features/mine/widgets/`（`ShelfGrid<T>`、`RecentList<T>`、`MineTabBody<TData>`）。
- 底部弹层：一律走 `lib/app/widgets/app_bottom_sheet.dart` 的 `AppBottomSheet` + `showAppBottomSheet()`，不要再直接调 `showModalBottomSheet`（圆角/遮罩/底部安全区/标题区只在一处维护）。标题区把主标题与副标题当行内元素排：默认同一行，主标题过长自己折行，副标题不折行、一行放不下就落到下一行左对齐（等价 CSS `flex-wrap: wrap`）；右上角统一关闭按钮；内容走 `child` 插槽（插槽不自带左右内边距，标题区是 20，需要齐平由调用方自己加）。`title: null` 时不画标题区/分割线，只在右上角浮一个圆形关闭按钮（可用 `showClose: false` 去掉），必须同时传 `heightFactor`（详情类弹层用 0.72 并不显示关闭按钮）
- 列表页通用骨架：`lib/features/feed/`（`FeedState<T>` 分页状态、`FeedView<T>` 滚动/补屏/下拉刷新/底部状态、`FeedStaggeredGrid<T>` 瀑布流网格（列数 2/3，卡片不定高）、`FeedSearchField`（搜索页的整行输入框；推荐页已不用整行搜索框，入口收成顶栏一个图标按钮）、`FeedSectionTitle`、`FeedFooter`）。新列表页优先复用它，不要各写一套。搜索页的**行内**加载/失败/空态用行内紧凑提示（`SearchPage` 私有 `_SectionStatus`），不复用整页 `LoadingView`/`ErrorView`/`EmptyView`——两行里的一行不能撑满整屏
- 详情页通用组件：`lib/app/widgets/detail/detail_common.dart`（`DetailCoverHeader` 封面头、`DetailIntroCard` 简介+标签、`ExpandableIntro`、`DetailSectionHeader`、`DetailTagChip`）。小说/短剧详情共用，特殊模块（目录/选集）各自在 feature 内实现
- 详情状态：小说走 `lib/features/detail/detail_providers.dart`（`detailBundleProvider` / `detailShelfProvider`，autoDispose + 乐观更新）；短剧走 `lib/features/video/video_detail_providers.dart`（`videoDetailBundleProvider`；收藏态在 `lib/features/video/video_library_providers.dart` 的 `VideoShelfController`，同样乐观更新），两侧对称
- 我的页：统一页头（右上角缓存中心 + 设置两枚入口）+ 小说/短剧两个 tab（`CategoryTabBar` + `TabBarView`，内容保活、可左右滑；页头到 tabs、下划线到第一个区块标题都 8pt）；两个 tab 共用 `lib/features/mine/widgets/mine_tab_body.dart` 的 `MineTabBody<TData>`（数据未就绪时只渲染占位）；小说数据在 `lib/features/mine/mine_providers.dart`，短剧在 `lib/features/mine/mine_drama_providers.dart`
- 路由：`lib/app/router.dart` 的 `sealed class AppRoute<T>` + 每个路由一个 `final class`（`DetailRoute` / `VideoDetailRoute` / `ReaderRoute` / `VideoPlayRoute` / `SettingsRoute` / `CacheCenterRoute` / `SearchRoute` / `RankRoute` / `SyncLogRoute` / `CloudSyncDataRoute` / `AppLogRoute`），各自实现 `toRoute()`；页面用 `context.pushAppRoute(route)`。`MaterialApp` 不再注册路由表（没有 `AppRoutes` / `onGenerateRoute`）；`ReaderArgs` / `VideoPlayArgs` 仍是阅读页 / 播放页自己的入参
- providers：`lib/app/providers.dart`（`apiClientProvider`（把 `diagnosticLogStoreProvider` 注入 ApiClient）、`readingStoreProvider`、`bootstrapProvider`）；主题色 / 深浅色模式见上面的 `themeSeedProvider` / `themeModeProvider`；推荐流布局见 `lib/features/recommend/recommend_layout.dart` 的 `recommendLayoutProvider`（同样持久化，启动时由 `main.dart` 预读，避免首页先按双列渲染再跳）；搜索页见 `lib/features/search/search_providers.dart` 的 `searchQueryProvider`（autoDispose，页面关闭即清空）+ `searchResultsProvider`（按「分类 + 关键词」family 并行请求，换词即换 provider 实例）+ `searchCueProvider`（搜索框占位轮播热词，非 autoDispose：搜索页占位用）+ `hotSearchProvider`（空搜索页热搜榜，autoDispose、失败回退空榜：搜索历史仍可用）；排行榜见 `lib/features/rank/rank_providers.dart` 的 `rankCatalogProvider` / `rankPreviewProvider`（首页三个分类的榜单预览，失败/空榜返回 null，不影响推荐流）；热词占位组件 `lib/features/search/search_cue_hint.dart`
- ProviderScope 已在 `lib/main.dart` 里，页面直接用 `ConsumerWidget` / `ConsumerStatefulWidget`

**`lib/features/*/` 的页面已按下文清单实现；新增/改动页面时仍按本文件的约定。**

## 硬性规则

1. **只改自己 feature 目录里的文件**（见各自任务说明）。共享文件（`lib/app/**`、`lib/data/**`、`lib/core/**`、`lib/src/rust/**`、`rust/`、`ios/`）一律不要改（新增依赖见规则 2，由 Lead 统一处理）。缺共享组件就在自己的目录里写。
2. **依赖受控新增。** 默认只用 pubspec 里现有的包；确实要用社区实现时，先确认没有现成方案、在本文件登记白名单，并同步 `pubspec.yaml` 注释。当前白名单：`flutter_staggered_grid_view`（推荐流双列/三列瀑布流，卡片不定高；自己写 RenderSliver 的测量/回收成本更高。**钉 0.8.0-dev.3**：0.7.x 的 SDK 上界是 `<3.0.0`，Dart 3 解析不到，不要改成 `^0.7.0`）、`cached_network_image`、`flutter_cache_manager`、`html`、`shared_preferences`（只剩主题/阅读器设置等偏好）、`sqflite`（书架/收藏/进度的本地库，模型见 `docs/storage-model-proposal.md`）、`flutter_secure_storage`、`path_provider`。`video_player` 是视频域专用：只允许 `lib/features/video/` 使用，播放器细节见 `docs/implementation.md`。`video_player_avfoundation` 通过 `third_party/` 本地补丁覆盖（defaultRate 倍速修复，见 `third_party/README.md`），不要直接改 pub cache。
3. **不要跑 `flutter build` / `flutter run`**（很慢，由 Lead 统一验证）。用 `flutter analyze lib/features/<你的域>` 自检，必须 0 error 0 warning。
4. UI 文案用中文；注释写"为什么"，不要写"做了什么"。
5. 只用 Material 3 + `Theme.of(context).colorScheme`，不要硬编码颜色（阅读页底色用 `ReaderPaper`；推荐流卡片的纯白底 / 暗色底统一走 `AppTheme.mediaCardColor`）。
6. 列表图片一律走 `NovelCover`（处理空 URL/失败），不要裸 `Image.network`。
7. 封面一律取缩略图：解析时用 `lib/data/models/json_utils.dart` 的 `coverKeys`（`thumb_url` 优先），不要回退到 `detail_page_thumb_url` / `cover` 之外的大图。封面位宽度：推荐流/搜索结果/我的页统一左右留白 8，双列约 183pt、三列约 119pt（书架/收藏网格同为 3 列约 119pt）；详情页封面铺成整屏宽渐变背景（`DetailCoverBackdrop`，不模糊），大图也用不上。`NovelCover` 按 `width * dpr` 解图，卡片变宽会自动跟着涨，不要手动写死解码宽度。书架与阅读进度会把 `cover` 落盘，存大图 URL 等于永久多付带宽。
8. 封面像素比例按内容类型取**上游原生比例**：小说 `kNovelCoverAspect`（320/240 = 4:3）、短剧/漫剧 `kVideoCoverAspect`（571/400 ≈ 10:7），定义在 `lib/app/widgets/novel_cover.dart`，由卡片类型/面板显式传入。推荐流瀑布流、搜索结果、书架、最近阅读、缓存中心都用原生比例，封面不被裁切；小说与短剧封面高度因此不同（7:10 比 3:4 高约 7%），切分类 tab 时卡片会变高，属预期。`kCoverAspect`（11:8）只作为 `MediaCard` / `NovelGridCard` / `VideoCard` 的默认值保留，页面入口不要依赖默认值。接口不返回封面尺寸，不要按单张图解码量尺寸（会在瀑布流里二次重排）。

## 数据层 API（已完成，直接用）

```dart
final api = ref.watch(apiClientProvider);

// 推荐流（小说 tab_type=2）。翻页必须回传 sessionId，否则上游会换设备导致 101116。
Future<FeedPage<NovelItem>> recommend({int offset = 0, String? sessionId});
// FeedPage<T> { List<T> items; int? nextOffset; String? sessionId; bool get hasMore }

// 搜索（书籍 tab_type=3）
Future<FeedPage<NovelItem>> search(String query, {int offset = 0});

// 短剧/漫剧推荐流与搜索（首页 tab_type：8 短剧 / 24 漫剧；搜索 tab_type=11 短剧）
Future<FeedPage<VideoSeries>> videoFeed({int tabType = 8, int offset = 0, String? sessionId});
Future<FeedPage<VideoSeries>> searchVideos(String query,
  {int tabType = 11, int offset = 0, bool manjuOnly = false});

// 搜索框轮播热词（cue）：一次返回整组词 + 轮播间隔 rotateIntervalMs，UI 自己轮播；
// 解析失败由调用方静默回退静态提示（`SearchCue.empty`）。
Future<SearchCue> searchCue({int tabType = 2, String tabName = '', int cueType = 0});

// 空搜索页热搜榜（官方 472 热搜榜 `/api/v1/search/hot`，最多 50 条、页面最多取前 30）：
// `tag_attached` 线上形如 `热门讨论·39054552热搜值`；去掉「热搜值」后保留前缀，
// 数字换算成整数 w+（`热门讨论·3905w+`）；失败回退空榜。
Future<HotSearch> hotSearch();

// 排行榜：目录藏在小说首页的排行榜 cell 里；条目走 /api/v1/rank/{rankId}。
// genreTab：小说 2 / 短剧 4 / 漫剧 5（不带时短剧/漫剧会被上游按小说榜回答）。
Future<RankCatalog> rankCatalog();
Future<RankBoard> rankBoard({required String rankId, required int algo,
  required int genreTab, int categoryId = 0, int offset = 0, int startAt = 1});

Future<BookDetail> bookDetail(String bookId);
Future<VideoDetail> videoDetail(String seriesId);
Future<List<Chapter>> directory(String bookId);           // 已摊平，Chapter{id,title,volumeName,index}
Future<List<Chapter>> videoEpisodes(String seriesId);     // 与 directory 同一条路由
Future<ChapterContent> chapter(String itemId, {String title = ''});
Future<Map<String, ChapterContent>> chaptersBatch(List<Chapter> chapters, {Duration timeout = const Duration(seconds: 40)}); // 离线整本下载用，阅读页不调用

// 评论 / 段评（只读，匿名设备签名，见下文「评论 / 段评」）
Future<ChapterIdeas> chapterIdeas(String itemId, {String itemVersion = '', int commentSource = 3}); // 整章段评计数 + 评论 id
Future<BookCommentPage> paragraphComments(String bookId, String itemId, {required int paraIndex, required String itemVersion, int count = 20, String cursor = ''}); // 某段/章末桶的段评正文
Future<BookCommentPage> bookComments(String bookId, {int count = 10, int offset = 0}); // 详情页书评（旧接口，带评分/context）
Future<CommentReplyPage> commentReplies(String commentId, {required String bookId, required String groupId, int count = 10}); // 评论回复，groupId = 章节 itemId
Future<BookCommentPage> seriesComments(String seriesId, {int count = 20, String cursor = '', int sort = 1}); // 短剧整体剧评，cursor 翻页
Future<BookCommentPage> episodeComments(String seriesId, String vid, {String cursor = ''}); // 某一集评论（官方热评，20 条/页，cursor 翻页）
Future<VideoSource> videoSource(String episodeId, {bool refresh = false, int? maxHeight, int? preferHeight}); // refresh=1 删缓存重下；默认带 variants=0；在线播放传 preferHeight=720（优先 720P，无 720 取最高档）；maxHeight=缓存质量上限
Future<String?> cachedVideoUrl(String episodeId); // mode=cached：只查本地 /src，不打上游
// 以上错误统一抛 ApiException（message 可直接展示）
```

分类差异不要写在页面或 `ApiClient` 里：`ContentSource` 的 `feed()` / `search()` 各自决定 `tab_type`、搜索走哪个 tab、漫剧没有游标时怎么用搜索兜底。`ApiClient` 只保留上游端点本身，不再有 `manjuSearch` 这类按分类分叉的方法。

`FeedPage<T>`：`items / nextOffset / sessionId`，`hasMore` 是 getter（只认 `nextOffset` 是否前进，不信上游 `has_more`）。
`NovelItem`：`id / title / cover / author / intro / category / wordCount / score / lastChapter`，`isValid` 表示可展示。
`BookDetail`：`bookId / title / cover / author / abstract / category / creationStatus(0连载 1完结 -1未知) / wordNumber / serialCount / readCount / score / tags / lastChapterTitle`，另有 `statusLabel / wordLabel / metaParts`。
`Chapter`：`id / title / volumeName / index / version`（`version` 来自目录，段评正文必填）；`ChapterContent`：`id / title / List<String> paragraphs / List<int?> paraIndices`（`<p idx="N">` 锚点，与 paragraphs 等长）。
评论模型：`BookComment` / `BookCommentPage`（段评、书评共用）、`ChapterIdeas` / `ParagraphIdeas`（段评计数）、`CommentReply` / `CommentReplyPage`。
`VideoSeries`：短剧/漫剧卡片；`VideoDetail`：详情字段 + 选集数等；`VideoSource`：可播放地址 + key + variants。

### 错误模型

`ApiException { String message; String? code; ApiErrorKind kind }`。`kind` 取值 `bad_input / device_failed / rate_limited / upstream_5xx / timeout / too_large / unknown`，wire 值与 Rust 内核一致（错误 JSON 里带 `kind` 字段）。

- `ApiErrorKind.isTransient`（`rateLimited` / `upstream5xx` / `timeout`）、`needsRestart`（`deviceFailed`）、`userCopy`（kind 的兜底人话短句）；`ApiException.isRetryable` / `needsRestart` 是同一套语义的实例入口（`unknown` 按可重试处理：本地意外，再试一次可能就好）。
- 统一文案 `apiErrorCopy(error, fallback:)`（`lib/data/models/json_utils.dart`）：后端给了具体 message 就优先保留，只有 "HTTP 500" 这类技术兜底 message 才换成 `userCopy`；非 `ApiException` 用 `fallback`。
- 行为策略：翻页失败时 `FeedState.loadMoreRetryable` 决定 footer 是否显示「重试」；`badInput` / `tooLarge` / `deviceFailed` 这类不可重试错误不显示按钮，`retryLoadMore()` 也直接不发请求。
- B2 超时归一：内核 504 在传输层抛 `BackendTimeoutException`，`ApiClient` 归一成 `ApiException(kind: timeout)`；499 取消仍是 `TimeoutException`（用户不可见，不转成 ApiException）。
- **仍不做通用 Dart 自动重试 / 退避循环**：重试与退避在 Rust 内核，Dart 只决定「要不要给用户一个重试入口」。唯一例外是推荐流首屏：可重试失败做 2 次短退避（400ms / 800ms，覆盖首次安装的联网权限弹窗），App 回前台（`resumed`）时对停在错误态的首屏补拉一次；确定性失败不重试（`lib/features/recommend/recommend_controller.dart`、`recommend_page.dart`）。
- 回环自愈契约（Apple TN2277）：iOS 长时间挂起可能回收内核回环监听的底层资源（FFI 仍正常，真实 socket 连接被拒）。内核 supervisor 在**同端口**自愈重绑（baseUrl / capability / `/src` 免鉴权面不变，已发出的播放地址继续有效）；Dart 侧 `BackendTransport.waitForLoopbackHealthy()` 用 `dart:io` 真实 HTTP `GET /health` 探活（FFI 请求不经过回环 adapter，探不出来），`BackendService.ensureLoopback()` 在探活失败时串行执行整核 `shutdown`+`init` 兜底；播放页对 -1004 只做**一次**有界恢复重试（恢复，不是通用自动重试循环）。

## 本地存储 API（已完成）

```dart
final store = ref.watch(readingStoreProvider);

// 小说：书架 + 进度
Future<List<NovelItem>> shelf();
Future<bool> isOnShelf(String bookId);
Future<void> addToShelf(NovelItem item);
Future<void> removeFromShelf(String bookId);
Future<void> saveProgress({required String bookId, required String bookTitle,
  required String cover, required String chapterId, required int chapterIndex,
  int blockIndex = 0});
Future<ReadingProgress?> progress(String bookId);      // chapterId / chapterIndex / blockIndex
Future<List<ReadingProgress>> recent({int limit = 3}); // 按时间倒序
Future<String?> lastReadBookId();

// 短剧：收藏 + 观看进度
Future<List<VideoSeries>> videoShelf();
Future<bool> isVideoOnShelf(String seriesId);
Future<void> addVideoToShelf(VideoSeries item);
Future<void> removeVideoFromShelf(String seriesId);
Future<void> saveVideoProgress({required String seriesId, required String title,
  String cover = '', required int episodeIndex});
Future<VideoWatchProgress?> videoProgress(String seriesId);
Future<List<VideoWatchProgress>> videoHistory({int limit = 3});
```

变更计数拆成 `novelRevision` / `videoRevision` 两个 `ValueNotifier<int>`：短剧每次换集只 bump 短剧侧，不让小说侧 provider 跟着重读本地数据。进度表有 LRU 200 本上限（最近阅读是独立表、只留 3 条，不受淘汰影响）。

## 离线缓存（pinned 区，只手动清理）

设计依据：[docs/implementation.md](docs/implementation.md)。两区目录：`<AppSupport>/offline/novel/<bookKey>/`、`<AppSupport>/offline/video/<seriesKey>/`。

```dart
// 存储（构造函数可注入 OfflinePaths，测试用临时目录）
final books = ref.watch(offlineBookStoreProvider);      // OfflineBookStore
final series = ref.watch(offlineSeriesStoreProvider);   // OfflineSeriesStore
await books.read(bookId);            // manifest（OfflineBook?）
await books.readChapter(bookId, chapterId);             // 离线正文（offline-first 读）
await series.episodeFile(seriesId, episodeId);          // 已缓存集 → File?（未缓存 null）
await books.stats();                 // OfflineStats{count, bytes, capBytes}
await books.delete(bookId);          // 手动删除单本

// 下载（进程级单任务；已有任务时返回 OfflineStartDisposition.queued 并入队，
// 超上限抛 OfflineQuotaExceeded，队列满抛 OfflineQueueFullException）
final downloader = ref.read(offlineDownloaderProvider.notifier);
await downloader.startNovelBook(bookId: id, title: t, cover: c, chapters: chapters);
await downloader.startVideoSeries(seriesId: id, title: t, cover: c, episodes: episodes);
downloader.pause(); / await downloader.resume(); / downloader.cancel();
await downloader.clearFor(OfflineTaskKind.novel, bookId);   // 删除前取消任务/撤排队项
// 缓存中心页的 M3 删除/清空就调 clearFor + store.clearAll；设置页只保留自动缓存清理/取消排队

// 等待队列（只在内存里，最多 20 个；完成/失败/取消后自动启动下一个）
final queued = ref.watch(offlineQueueProvider);             // List<OfflineQueuedTask>
ref.read(offlineQueueProvider.notifier).remove(kind, id);   // 取消排队

// UI：详情页底部悬浮圆按钮（小说/短剧共用，从左到右 收藏 / 缓存 / 播放·阅读，只有图标、靠右排列）；三态「缓存/缓存中/已缓存」，
// 缓存 → start*；缓存中/已缓存 → push CacheCenterRoute()（暂停/继续/重试在缓存中心）
DetailActionBar(offlineButton: OfflineDownloadButton(
  kind: OfflineTaskKind.novel, id: bookId, title: title, cover: cover, items: chapters))

// 缓存中心页数据：已下载看 list provider，下载中看 offlineTaskProvider
final task = ref.watch(offlineTaskProvider);   // OfflineTask?（含 speedBytesPerSecond 瞬态网速）
```

不变式（改动时不要破坏）：

1. 离线区不参与任何自动淘汰/TTL/体积裁剪；`AppCache.clear()` 只枚举自动缓存目录，**永不碰 `offline/`**（`test/cache_test.dart` 有回归用例）。
2. 小说 / 短剧两个区相互独立：目录、manifest、统计、清空互不影响。
3. 软上限：小说 1 GiB、短剧 3 GiB（`OfflineBookStore.novelCapBytes` / `OfflineSeriesStore.videoCapBytes`），超限阻止新任务并引导清理。
4. 下载任务同一时刻只有一个，其余 FIFO 排队（内存队列，上限 20，按 kind+id 去重）；当前任务完成/失败/取消后自动启动下一个，paused 时队列停住；切后台在当前章/集结束后暂停、回前台不自动继续；删除区/条目之前先 `clearFor` 取消任务/排队。队列不持久化（重启后等待项消失，当前任务恢复成 paused）。
5. manifest schema 读不懂时当"没有缓存"处理，不删文件（交给用户手动清理）。

## 评论 / 段评（只读）

数据链路（内核已有接口，Rust 零改动；Dart 走 FFI，不受 loopback `APP_APIS` 白名单限制）：

1. `chapterIdeas(itemId, itemVersion)`：`GET /api/v1/chapters/{id}/reviews` → 上游 idea list，返回
   `data.data` 按段落 id 分桶的 `count` / `infos[].comment_id`（整章一次，不分页）。
2. `paragraphComments(bookId, itemId, paraIndex, itemVersion)`：`GET /api/v1/books/{id}/reviews`，
   带 `group_id=章节id, group_type=15, comment_source=2, comment_type=1, server_channel=38`，
   `cursor` 翻页；段评和工具栏「评论」共用这一条（章节桶 = idea map 里**段号最大**的桶，约定 10000+）。
3. `commentReplies(...)`：`GET /api/v1/comments/{id}/replies`，点击「N 条回复」时懒加载。

约定：

- **只读**：没有发评论/点赞/回复入口；匿名设备签名，无账号登录。
- **失败静默**：段评是装饰，`chapterIdeasProvider` 失败一律 `ChapterIdeas.empty`，不能把阅读页打成错误态。
- **锚点**：正文解析必须保留 `<p idx="N">`（`ChapterContent.paraIndices`）与目录 `version`；
  没有锚点的段不画气泡。升级前缓存/下载的正文缺锚点（schema 落后）且气泡开启时，阅读页
  后台补取一次正文，只有真拿到锚点才回填当前章（离线来源只在会话内复用，不覆盖离线区）；
  纯文本回退源补取后仍无锚点、不替换正文；工具栏「评论」始终按计数可用。
- **气泡位置**：只跟段末行同行；末行放不下时**不画**（避免独占一行或被下一段裁切）。
- **气泡样式**：自绘空心对话气泡（透明底 + 主题色描边 + **左侧朝左**尾巴，数字居中，
  `>99` 显示 `99+`），variant 只换描边/数字配色，不引图片素材；尺寸常量在 `ReaderParagraphBubble`。
  尾巴朝左指向被标注的段落，不朝下（朝下会顶到下一段行首）。
- **汇总不闪**：目录后台刷新把章 `version` 从空换成网络值时 idea list 会重新请求，
  阅读页同一章沿用上一份汇总直到新结果返回，不能让气泡先消失再出现。
- **请求频率**：气泡开 = 每章 1 次 idea list；老缓存补锚点 = 该章首次 +1 次正文（自动缓存
  来源写回新 schema 后不再发；离线来源每章每次会话各一次）；气泡关 = 0 次（点工具栏
  「评论」才按需取）；面板/回复/书评翻页全部由用户手势触发，无轮询、无后台预取、无逐段请求。
- **离线**：离线阅读不请求评论（无网络必失败），入口/气泡自然为空。
- **缓存**：`reader_chapters/` 与 `offline/novel/` 的章节 JSON 带 schema 版本 `v` 与可选
  `paraIndices`；读取时长度对不上就当没有锚点（宁可少画气泡，不能把段评挂错段）。
  没有 `v` 的老文件按 0 算，命中后标记 `ReaderChapterHit.anchorsOutdated`。

### 短剧评论（只读）

内核 `comments.rs` 里短剧读路由早就有了，Dart 侧直接走 FFI，不需要改 Rust：

1. `seriesComments(seriesId)`：`GET /api/v1/series/{sid}/comments` → 整部剧的剧评。
   上游 `comment_source=1 / group_type=1(Book)`，`cursor` 翻页；详情页剧评卡片取首屏，
   同一页数据复用给「全部剧评」弹层，打开弹层不再重复拉首屏。
2. `episodeComments(seriesId, vid)`：`GET /api/v1/series/{sid}/hot-comments?vid={vid}` → 某一集的评论
   （`comment_source=4 / comment_type=4 / group_type=30(SeriesVideo) / server_channel=18`），
   `common_list_info.total` 就是该集评论数。`business_param.book_id` 按官方用剧集 id；
   关键字段是 `server_channel=18`（17 会返回 total>0 但 `data_list` 为空的「成功」响应）。
   上游每页最多 20 条，响应 `common_list_info.cursor` 是带 `session_id`/`offset` 的 JSON 串；`episodeComments` 原样回传即可翻页。
3. 弹幕（`GET /api/v1/videos/{vid}/danmaku`）是另一条链路（按播放时间轴取数），本期不接。

约定：

- **vid 不能空**：上游 vid 为空时会静默退回剧集 id（变成整部剧的评论）；`episodeComments`
  在 vid 为空时直接返回空页、不发请求。
- **模型复用**：短剧评论与段评/书评共用 `BookComment` / `BookCommentPage`，但短剧评论没有
  `score`，详情卡片和弹层都不画星级（`showStars: false`）。
- **失败静默**：`videoSeriesCommentsProvider` 失败返回 null，详情页整块不插入剧评卡片，不制造错误态。
- **列表壳共用**：阅读页段评/章评、详情页书评、短剧剧评、本集评论统一走 `lib/app/widgets/comment_list_sheet.dart` 的 `CommentListSheet` + `CommentFeed`；书评的 offset 分页、短剧/段评的 cursor 分页、段评的回复懒加载、阅读页纸色主题分别在各自的 Feed/Style 里，UI、空态、失败重试、翻页 footer、评论行排版只有一份。
- **只读**：不提供发评论/点赞/回复入口（内核有写接口，本期不接）。

## 导航

```dart
// 类型化路由：路由对象自带强类型参数，传错在编译期就报错。
context.pushAppRoute(DetailRoute(bookId: item.id, preview: item)); // preview / heroTag 可空
context.pushAppRoute(VideoDetailRoute(seriesId: item.id, preview: item, heroTag: tag));
context.pushAppRoute(ReaderRoute(ReaderArgs(bookId: id, chapterId: null, blockIndex: 0)));
context.pushAppRoute(VideoPlayRoute(VideoPlayArgs(
  seriesTitle: title, episodes: episodes, index: index)));
context.pushAppRoute(const SettingsRoute());
context.pushAppRoute(const AppLogRoute());         // 设置 → 诊断 → 运行日志
context.pushAppRoute(const CacheCenterRoute());    // 我的 → 缓存的下载中心（进度/网速/暂停续传）
context.pushAppRoute(const SearchRoute());         // 推荐页顶栏搜索入口 → 独立搜索页（搜索词是页面自己的状态，不走路由参数）

// 等价写法：Navigator.of(context).push(route.toRoute())
```

路由类与 `pushAppRoute` 扩展都在 `lib/app/router.dart`，`toRoute()` 内部用 `MaterialPageRoute`；没有路由表、中间件或深链，也不要加 go_router。

## 状态管理约定

- 每个 feature 自己建 `*_provider.dart`：`AsyncNotifierProvider` / `NotifierProvider` / `FutureProvider.family`，**不要**把状态塞进页面 `setState`（纯 UI 动画状态除外）。
- 页面 = `ConsumerWidget`/`ConsumerStatefulWidget`，只做布局与交互，不直接 new ApiClient。
- 下拉刷新 → `ref.invalidate(provider)` 或控制器 `refresh()`。
- 加载/错误/空态统一用 `LoadingView` / `ErrorView(message, onRetry)` / `EmptyView`。
- 本地数据变更靠 `ReadingStore` 的 `novelRevision` / `videoRevision`：provider 里 `watch` 对应 revision 即可自动刷新，不要自己轮询。
- 书架/收藏/进度落在 SQLite（`lib/core/storage/library_db.dart`），页面只经 `ReadingStore` 读写；测试里的内存库与逐用例重置由 `test/flutter_test_config.dart` 统一处理，不要再往 `shared_preferences` 塞这些数据。

## 测试与工程质量

- UI 测试在 `test/ui/`（按页面拆：recommend / search / home / detail / video / reader / mine / settings / 缓存中心，共享 `test/ui/preview_harness.dart`），共 31 张 golden；排行榜另有 `test/rank_test.dart`（目录/book/video 解析、分页、分类映射）与 `test/ui/rank_page_test.dart`（二级 tab、initialAlgo 自动定位、左右滑、已请求 tab 数据保留、列表字段、首页榜单区块（榜名在卡片外、前十、可横滑、短剧/漫剧也有））；搜索页另有用例锁「小说/短剧两行顺序 / 卡宽 = 一屏 3.5 张 / 骨架加载 / 失败重试 / 换词不串结果 / 空输入提交搜占位热词 / 热搜榜前三十（超出 30 条截断）与前三标红、无历史时仍展示」（`test/ui/search_test.dart`）；热搜解析与 `w+` 格式另有 `test/hot_search_test.dart`；瀑布流布局本身另有 `test/ui/feed_staggered_grid_test.dart`（不定高卡片按列排 + 双列/三列基线），推荐布局偏好见 `test/recommend_layout_test.dart`；根目录 `test/*_test.dart` 是解析 / 缓存 / 并发 / 存储 / 主题测试。
- 评论/段评：`test/comment_models_test.dart`（响应形状 + 段落锚点）、`test/reader_comments_sheet_test.dart`（面板分页/回复/失败态）、`test/reader_pagination_bubble_test.dart`（气泡占位与重排）、`test/ui/detail_reviews_test.dart`（书评卡片/弹窗）。
- 真机性能 harness：`integration_test/reader_pagination_perf_test.dart`（`flutter drive --profile`，不进 `flutter test` / CI；结论见 `docs/implementation.md` §8）。
- CI 在 `.github/workflows/ci.yml`：Dart format / analyze / test、Rust fmt / clippy / test、FRB 绑定漂移校验、iOS 无签名构建。本地等价命令 `make check`（只做格式化用 `make format`）。
- Rust 内核是 fqapp 的 fork：基线 commit、本地补丁清单与上游同步流程都在 `PATCHES.md`；改 `rust/` 必须同步更新它。

## 页面清单（已实现）

1. 推荐页：**小红书式顶栏**（整行与 tabs 同高 32pt、贴住安全区、常驻不随列表收起）——分类 tabs（小说 / 短剧 / 漫剧，与我的页共用 `CategoryTabBar`，整组在屏幕正中、当前分类带下划线）在左，右侧一个独立的放大镜图标（`search_rounded`，**无底色**、和我的页头图标同一套线性样式，Tooltip/无障碍文案「搜索」）：点一下进独立搜索页。顶栏不再有整行搜索框、也没有缓存入口（缓存入口挪到我的页头）；下划线贴行底，下面再留 8pt 给内容。顶部固定模块带很淡的蓝粉氛围渐变（左→右、向下淡出，`TopGlow`）+ 各分类推荐流（白底卡片 + 不定高瀑布流，默认双列、设置里可切三列；左右留白与行/列间距都 8；封面按内容域原生比例出图；底部导航只剩「推荐 / 我的」）；瀑布流上方是榜单区块（与搜索结果页同一版式：榜名「推荐榜」/「短剧榜」/「漫剧榜」在卡片**外面**、右侧「更多」进排行榜页；下面一行是与搜索结果同款的紧凑卡（前 10 条、一屏露 3.5 张、无 1/2/3 标号、横向可滑；失败/空榜会重试一次，两次都拿不到才收起）；首次加载先铺同口径骨架，标题行顶部与 tabs 下划线之间留 8pt）
2. 详情页：封面/书名/作者/分类/状态/字数/简介/标签 + 书评卡片（首条 + 弹窗查看全部）+ 目录 + 底部「开始阅读」；短剧详情是同一套版式，只是把书评/目录换成剧评卡片（首条 + 弹窗查看全部）与选集
3. 阅读页：分页正文 + 段评气泡 + 工具栏「评论」/评论面板（分页/回复只读）+ 点击呼出工具栏 + 顶部左侧书名（与右侧动作同字号，占剩余宽度、超宽省略）+ 书架状态（加入书架→已在书架，只读，只加不移）/整本缓存状态（缓存小说/缓存中/已缓存，缓存中与已缓存点击进缓存中心）文本动作 + 底部日间/夜间切换（夜间黑色纸，日间回上次选的浅色纸）+ 三章预取窗口（当前 ±1 章：正文/章评/分页；窗口外淘汰，边界 sentinel 页复用 PageView 动画）+ 详情弹层（目录右边入口，无标题、无关闭按钮、不重复目录，只有收藏/缓存）+ 字号/行距/字重（300–800）/底色（色块与标题同行）/段评气泡开关 + 进度保存；上一章/下一章不占工具栏按钮（空章兜底仍保留），点正文左右分区/章边界滑动/目录跳章都能切章
4. 短剧播放页：控制条底排左侧「选集 + 详情 + 本集评论」、中间播放/暂停、右侧「清晰度（仅展示）+ 倍速」；倍速点开是贴着 chip 的小浮窗（M3 MenuAnchor 竖排档位，选完即关，打开时控制条不自动隐藏），不是底部弹层；收藏/缓存收进「详情」底部弹层（历史「最近观看」直进播放页时也从这里操作；弹层不重复选集、无关闭按钮）；进度条两侧显示当前时间/总时长；上下滑切集、播完自动续播、横屏全屏
   - **收藏只加不移**（与阅读页顶部「加入书架」一致）：已收藏后按钮只读，取消走「我的 → 收藏」；成功不弹提示条，图标变实心即可。
   - 缓存三态与详情页共用 `offlineEntryStatusProvider`：未缓存开下载，缓存中/已缓存进缓存中心。
5. 我的页：**统一页头**（图标 + 「我的」 + 合并统计「书架 N 本 · 收藏 M 部」 + 右上角**缓存中心**与**设置**两枚线性图标按钮，缓存在前、设置在后，固定贴顶、不随内容滚动）+ 小说 / 短剧两个 tab（与推荐页共用 `CategoryTabBar`：左对齐、带下划线、整行高度固定 32，首个 tab 文字与内容留白左对齐（按选中态加粗预留宽度），当前 tab 主题色高亮、字号与未选中一致（15）；颜色/字重跟着切换动画连续插值、下划线滑过去（拖动时跟着手指走，只有无障碍 `selected` 过半才切）；点击或左右滑动切换，tab 内容各自独立滚动并保活）；页头下沿到 tabs、tabs 下划线到第一个区块标题都是 8pt（上下等宽，不再一段 8 一段 16）；整页共用一套蓝粉氛围渐变（方向与推荐页略有差异），不随 tab 变化。小说 tab = 最近阅读 + 我的书架；短剧 tab = 最近观看 + 我的收藏（点击直接续播对应集）；两个 tab 共用 `MineTabBody` 骨架与页头，数据/空态/长按管理各自独立
6. 设置页：**每个区块共用一张卡、卡内不画分割线**。主题卡：主题色（3 个预设 + HSV 自定义取色，全站生效并持久化）→ 深浅色模式（跟随系统 / 手动深色，持久化）→ 推荐流布局（双列 / 三列按钮组 `SegmentedButton`，默认双列，持久化）→ 全局字重（仅 Android，300 / 400 / 500 三档按钮组，阅读器默认跟随并可覆盖）→ 对话高亮（主题卡最后一项；圆形色块打开弹层：荧光笔 / 下划线 / 波浪线按钮组 + HSV 取色，示例正文按当前样式与颜色实时预览）。同步卡：WebDAV / 同步记录 / 云端数据三个入口（书架/收藏/进度，凭据进 Keychain/Keystore，release/beta/dev 分目录）。存储卡：视频/封面/章节/遗留日志明细（无行首图标）+「共 x MB」与「不包括主动下载」同一行底边对齐 + 清理图标按钮；缓存质量单独一张卡（Max / 1080P / 720P / 480P 按钮组）
7. 缓存中心：我的页页头右上角「缓存」图标进入（在设置左边；推荐页顶栏已无缓存入口）；小说/短剧分区列出下载中/排队中/已下载，进度条 + 实时网速，暂停/继续/重试/取消排队，M3 删除与按区清空（确认框），点条目 Hero 进详情
8. 搜索页（独立页，推荐页顶栏搜索图标点进来）：顶部搜索框（自动聚焦，右侧「取消」返回；占位轮播热词，**空输入提交时直接搜当前占位热词**并把它填回输入框）+ 一次提交**搜小说 / 短剧**，从上到下依次是 小说 / 短剧 两行；每行横向可滑、一屏露出约 3.5 张卡；卡片复用首页推荐流同款（白底卡 + 原生封面比例），卡宽按屏宽算、字号整体缩一档（都在 `CompactCardRow`：一屏 3.5 张、`cardFontScale` = 0.88）；每行独立 加载骨架（与真卡同宽同高的色块占位）/ 失败重试 / 空态；**不单列漫剧行**——漫剧没有独立搜索 tab，是借短剧搜索 tab 再按 `genre=205` 过滤的，和短剧行本质是同一份响应；单列会把同一份数据请求两遍并在两行重复出现，所以短剧行直接展示上游混排结果（漫剧卡片混在其中）；视频卡不展示推荐理由（`recommend_reason_list` 第一条：或为分类名「漫剧」、或为「上新」角标，都隐藏），只留「全 N 集 + 热度」；点卡片按内容域进详情（Hero tag 带 `search-<分类>` 来源）。v1 每个分类只取首屏一页（暂不接 `next_offset`，没有「查看更多」）；输入为空时展示搜索历史（最多 10 条、去重置顶、点击直接重搜）+ 下方热搜榜（`/api/v1/search/hot`，最多 30 条（接口一次 50 条，超出截断）；名次 1–3 用 `colorScheme.error` 标红，标题后展示 `display_tag` 彩色角标，右侧保留接口前缀并把热度数字换算成整数 `3905w+`，点一条直接按该词搜索；没有历史时热搜榜仍展示，两者都空才显示引导空态）

9. 排行榜页（独立页，首页榜单区块「更多」进入，带 `initialAlgo` 自动定位）：AppBar「排行榜」+ 横滑二级 tab（推荐榜 / 完本榜 / 巅峰榜 / 新书榜 / 短剧榜 / 漫剧榜，按小说→短剧→漫剧排序；无下划线，内容区用 TabBarView 左右滑切榜，每个 tab 独立请求并 keep-alive，切回不重拉、滚动位置保留）；列表条目含名次（前三红）、封面、标题、评分、`作者 · 分类 · 热度`（短剧/漫剧为 `分类 · 全N集 · 热度`）、两行简介、题材标签，行间不画分割线；点条目按内容域进详情；触底翻页、下拉刷新、空榜/失败重试。短剧/漫剧榜请求必须带 `genre_tab=4/5`，否则上游会回小说榜。

不在本期范围：听书、漫画、登录；评论/段评只做**只读**（不发评论、不点赞、不回复）。
