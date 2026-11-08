# novel-playlet 开发契约（页面开发必读）

## 现在什么已经就绪

- Flutter 工程（iOS-only 目标，但不要改 `ios/` 与 `pubspec.yaml`；视频域专项例外见 [docs/playback-quality-speed.md](docs/playback-quality-speed.md) 与 `third_party/README.md`）
- Rust 内核 `rust/` 已完整拷入，FRB 绑定在 `lib/src/rust/`（**自动生成，不要手改**）
- 启动链：`lib/main.dart → BootstrapGate → BackendService.start() → Rust init`
- 业务接口：`lib/data/api/api_client.dart`（已封装 recommend / search / videoFeed / searchVideos / bookDetail / videoDetail / videoEpisodes / videoSource / cachedVideoUrl / directory / chapter）
- 模型：`lib/data/models/`（`NovelItem`、`BookDetail`、`Chapter`、`ChapterContent`、`FeedPage`、`VideoSeries`、`VideoDetail`、`VideoSource`、`json_utils`（含 `ApiErrorKind`））。卡片解析不在 model 层：统一在 `lib/data/parsers/`（`card_walker.dart` 的 `walkCards` / `CardAdapter` 骨架 + `novel_parsers.dart` / `video_parsers.dart`）
- 分类策略：`lib/features/recommend/content_source.dart` 的 `ContentSource`（`NovelSource` / `DramaSource` / `ManjuSource`）。上游 `tab_type`、搜索 tab、漫剧搜索兜底都在策略对象里；`lib/features/recommend/recommend_category.dart` 只留 label / searchHint / emptyIcon / source，页面不再按分类写 if
- 本地存储：`lib/core/storage/reading_store.dart`（书架、阅读进度、最近阅读、短剧收藏/观看进度）；阅读进度表按最近 200 本做 LRU 上限（`progressLimit`）。缓存：`lib/core/cache/`（封面缓存 `AppImageCache`、占用统计与清理 `AppCache`，入口在「我的 → 设置 → 存储」）
- 离线缓存：`lib/core/storage/offline/`（小说/短剧两个 pinned 区的 manifest 与原子读写）+ `lib/features/cache/`（单任务下载器、等待队列、任务持久化、providers、详情底栏三态按钮、缓存中心）。缓存中心同时负责浏览、暂停/继续/重试、删除/清空；设置页不再有离线入口。与自动缓存物理隔离、只手动清理，见下文「离线缓存」
- 主题：`lib/app/theme/app_theme.dart`（Material 3 seed 主题 + `AppAccent` 扩展 + `ReaderPaper` 阅读底色）；主题色偏好：`lib/app/theme/theme_settings.dart`（`themeSeedProvider`，持久化在 `shared_preferences`）。页面颜色一律走 `Theme.of(context).colorScheme`（M3 保证对比度），不要引用 `AppTheme.accent` 常量；只有「需要原始 seed 再自己派生 scheme」的场景（如阅读页按纸色明暗重建主题）才用 `AppTheme.accentOf(context)` + `AppTheme.schemeFor(seed, brightness)`
- 共享组件：`lib/app/widgets/`（`NovelCover`、`MediaCard`（列表卡共用骨架：封面 + 两行标题 + 一行元信息）、`NovelGridCard` / `VideoCard`（把模型映射成卡片文案的薄适配）、`LoadingView`、`ErrorView`、`EmptyView`）。我的页通用块在 `lib/features/mine/widgets/`（`ShelfGrid<T>`、`RecentList<T>`、`PanelShell<TData>`）。小说/短剧两侧只注入数据与文案，不要各写一套
- 列表页通用骨架：`lib/features/feed/`（`FeedState<T>` 分页状态、`FeedView<T>` 滚动/补屏/下拉刷新/底部状态、`FeedGrid<T>` 三列网格、`FeedResultsSliver<T>` + `FeedResultTile` 搜索结果横向列表（推荐页各分类共用）、`FeedSearchField`、`FeedSectionTitle`、`FeedFooter`）。新列表页优先复用它，不要各写一套
- 详情页通用组件：`lib/app/widgets/detail/detail_common.dart`（`DetailCoverHeader` 封面头、`DetailIntroCard` 简介+标签、`ExpandableIntro`、`DetailSectionHeader`、`DetailTagChip`）。小说/短剧详情共用，特殊模块（目录/选集）各自在 feature 内实现
- 详情状态：小说走 `lib/features/detail/detail_providers.dart`（`detailBundleProvider` / `detailShelfProvider`，autoDispose + 乐观更新）；短剧走 `lib/features/video/video_detail_providers.dart`（`videoDetailBundleProvider`；收藏态在 `lib/features/video/video_library_providers.dart` 的 `VideoShelfController`，同样乐观更新），两侧对称
- 我的页：两个面板共用 `lib/features/mine/widgets/panel_shell.dart` 的 `PanelShell<TData>`（数据未就绪时只渲染页头 + 占位）；小说数据在 `lib/features/mine/mine_providers.dart`，短剧在 `lib/features/mine/mine_drama_providers.dart`
- 路由：`lib/app/router.dart` 的 `sealed class AppRoute<T>` + 每个路由一个 `final class`（`DetailRoute` / `VideoDetailRoute` / `ReaderRoute` / `VideoPlayRoute` / `SettingsRoute` / `CacheCenterRoute`），各自实现 `toRoute()`；页面用 `context.pushAppRoute(route)`。`MaterialApp` 不再注册路由表（没有 `AppRoutes` / `onGenerateRoute`）；`ReaderArgs` / `VideoPlayArgs` 仍是阅读页 / 播放页自己的入参
- providers：`lib/app/providers.dart`（`apiClientProvider`、`readingStoreProvider`、`bootstrapProvider`）；主题色见上面的 `themeSeedProvider`
- ProviderScope 已在 `lib/main.dart` 里，页面直接用 `ConsumerWidget` / `ConsumerStatefulWidget`

**`lib/features/*/` 的页面已按下文清单实现；新增/改动页面时仍按本文件的约定。**

## 硬性规则

1. **只改自己 feature 目录里的文件**（见各自任务说明）。共享文件（`lib/app/**`、`lib/data/**`、`lib/core/**`、`lib/src/rust/**`、`rust/`、`ios/`、`pubspec.yaml`）一律不要改。缺共享组件就在自己的目录里写。
2. **不要新增依赖。** 只用 pubspec 里现有的包（flutter_riverpod、cached_network_image、flutter_cache_manager、html、shared_preferences、flutter_secure_storage、path_provider、video_player）。`video_player` 是视频域专用：只允许 `lib/features/video/` 使用，播放器细节见 `docs/video-playback.md`。`video_player_avfoundation` 通过 `third_party/` 本地补丁覆盖（defaultRate 倍速修复，见 `third_party/README.md`），不要直接改 pub cache。
3. **不要跑 `flutter build` / `flutter run`**（很慢，由 Lead 统一验证）。用 `flutter analyze lib/features/<你的域>` 自检，必须 0 error 0 warning。
4. UI 文案用中文；注释写"为什么"，不要写"做了什么"。
5. 只用 Material 3 + `Theme.of(context).colorScheme`，不要硬编码颜色（阅读页底色用 `ReaderPaper`）。
6. 列表图片一律走 `NovelCover`（处理空 URL/失败），不要裸 `Image.network`。
7. 封面一律取缩略图：解析时用 `lib/data/models/json_utils.dart` 的 `coverKeys`（`thumb_url` 优先），不要回退到 `detail_page_thumb_url` / `cover` 之外的大图。全 App 封面位最大 108pt 宽，详情 Hero 也只有 96×132；书架与阅读进度会把 `cover` 落盘，存大图 URL 等于永久多付带宽。
8. 封面像素比例统一走 `kCoverAspect`（`lib/app/widgets/novel_cover.dart`，11:8）：推荐网格、搜索结果、书架、最近阅读、详情封面全部用它，不要各写 `1.38` / `4/3` 这类字面量——上游小说 240×320 与短剧 400×571 原生比例不同，各写一套会让各分类的封面一高一矮。

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

Future<BookDetail> bookDetail(String bookId);
Future<VideoDetail> videoDetail(String seriesId);
Future<List<Chapter>> directory(String bookId);           // 已摊平，Chapter{id,title,volumeName,index}
Future<List<Chapter>> videoEpisodes(String seriesId);     // 与 directory 同一条路由
Future<ChapterContent> chapter(String itemId, {String title = ''});
Future<VideoSource> videoSource(String episodeId, {bool refresh = false, int? maxHeight}); // refresh=1 删缓存重下；默认带 variants=0；maxHeight=下载清晰度上限
Future<String?> cachedVideoUrl(String episodeId); // mode=cached：只查本地 /src，不打上游
// 以上错误统一抛 ApiException（message 可直接展示）
```

分类差异不要写在页面或 `ApiClient` 里：`ContentSource` 的 `feed()` / `search()` 各自决定 `tab_type`、搜索走哪个 tab、漫剧没有游标时怎么用搜索兜底。`ApiClient` 只保留上游端点本身，不再有 `manjuSearch` 这类按分类分叉的方法。

`FeedPage<T>`：`items / nextOffset / sessionId`，`hasMore` 是 getter（只认 `nextOffset` 是否前进，不信上游 `has_more`）。
`NovelItem`：`id / title / cover / author / intro / category / wordCount / score / lastChapter`，`isValid` 表示可展示。
`BookDetail`：`bookId / title / cover / author / abstract / category / creationStatus(0连载 1完结 -1未知) / wordNumber / serialCount / readCount / score / tags / lastChapterTitle`，另有 `statusLabel / wordLabel / metaParts`。
`Chapter`：`id / title / volumeName / index`；`ChapterContent`：`id / title / List<String> paragraphs`。
`VideoSeries`：短剧/漫剧卡片；`VideoDetail`：详情字段 + 选集数等；`VideoSource`：可播放地址 + key + variants。

### 错误模型

`ApiException { String message; String? code; ApiErrorKind kind }`。`kind` 取值 `bad_input / device_failed / rate_limited / upstream_5xx / timeout / too_large / unknown`，wire 值与 Rust 内核一致（错误 JSON 里带 `kind` 字段）。

- `ApiErrorKind.isTransient`（`rateLimited` / `upstream5xx` / `timeout`）、`needsRestart`（`deviceFailed`）、`userCopy`（kind 的兜底人话短句）；`ApiException.isRetryable` / `needsRestart` 是同一套语义的实例入口（`unknown` 按可重试处理：本地意外，再试一次可能就好）。
- 统一文案 `apiErrorCopy(error, fallback:)`（`lib/data/models/json_utils.dart`）：后端给了具体 message 就优先保留，只有 "HTTP 500" 这类技术兜底 message 才换成 `userCopy`；非 `ApiException` 用 `fallback`。
- 行为策略：翻页失败时 `FeedState.loadMoreRetryable` 决定 footer 是否显示「重试」；`badInput` / `tooLarge` / `deviceFailed` 这类不可重试错误不显示按钮，`retryLoadMore()` 也直接不发请求。
- B2 超时归一：内核 504 在传输层抛 `BackendTimeoutException`，`ApiClient` 归一成 `ApiException(kind: timeout)`；499 取消仍是 `TimeoutException`（用户不可见，不转成 ApiException）。
- **仍不做 Dart 自动重试 / 退避循环**：重试与退避在 Rust 内核，Dart 只决定「要不要给用户一个重试入口」。
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

设计依据：[docs/offline-cache.md](docs/offline-cache.md)。两区目录：`<AppSupport>/offline/novel/<bookKey>/`、`<AppSupport>/offline/video/<seriesKey>/`。

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

// UI：详情页底栏按钮（小说/短剧共用）；三态「缓存/缓存中/已缓存」，
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

## 导航

```dart
// 类型化路由：路由对象自带强类型参数，传错在编译期就报错。
context.pushAppRoute(DetailRoute(bookId: item.id, preview: item)); // preview / heroTag 可空
context.pushAppRoute(VideoDetailRoute(seriesId: item.id, preview: item, heroTag: tag));
context.pushAppRoute(ReaderRoute(ReaderArgs(bookId: id, chapterId: null, blockIndex: 0)));
context.pushAppRoute(VideoPlayRoute(VideoPlayArgs(
  seriesTitle: title, episodes: episodes, index: index)));
context.pushAppRoute(const SettingsRoute());
context.pushAppRoute(const CacheCenterRoute());    // 我的 → 缓存的下载中心（进度/网速/暂停续传）

// 等价写法：Navigator.of(context).push(route.toRoute())
```

路由类与 `pushAppRoute` 扩展都在 `lib/app/router.dart`，`toRoute()` 内部用 `MaterialPageRoute`；没有路由表、中间件或深链，也不要加 go_router。

## 状态管理约定

- 每个 feature 自己建 `*_provider.dart`：`AsyncNotifierProvider` / `NotifierProvider` / `FutureProvider.family`，**不要**把状态塞进页面 `setState`（纯 UI 动画状态除外）。
- 页面 = `ConsumerWidget`/`ConsumerStatefulWidget`，只做布局与交互，不直接 new ApiClient。
- 下拉刷新 → `ref.invalidate(provider)` 或控制器 `refresh()`。
- 加载/错误/空态统一用 `LoadingView` / `ErrorView(message, onRetry)` / `EmptyView`。
- 本地数据变更靠 `ReadingStore` 的 `novelRevision` / `videoRevision`：provider 里 `watch` 对应 revision 即可自动刷新，不要自己轮询。

## 测试与工程质量

- UI 测试在 `test/ui/`（按页面拆：recommend / home / detail / video / reader / mine / settings / 缓存中心，共享 `test/ui/preview_harness.dart`），共 23 张 golden；根目录 `test/*_test.dart` 是解析 / 缓存 / 并发 / 存储 / 主题测试。
- 真机性能 harness：`integration_test/reader_pagination_perf_test.dart`（`flutter drive --profile`，不进 `flutter test` / CI；结论见 `docs/reader-pagination-profile.md`）。
- CI 在 `.github/workflows/ci.yml`：Dart format / analyze / test、Rust fmt / clippy / test、FRB 绑定漂移校验、iOS 无签名构建。本地等价命令 `make check`（只做格式化用 `make format`）。
- Rust 内核是 fqapp 的 fork：基线 commit、本地补丁清单与上游同步流程都在 `PATCHES.md`；改 `rust/` 必须同步更新它。

## 页面清单（已实现）

1. 推荐页：顶部搜索输入框（40pt；继续往下浏览时整条收起、分类 tabs 吸顶；往回滚第一下立即展开、搜索态保持展开；收起后切分类保持收起）+ 可左右滑动的分类 tabs（小说 / 短剧 / 漫剧）+ 各分类推荐列表（底部导航只剩「推荐 / 我的」）
2. 详情页：封面/书名/作者/分类/状态/字数/简介/标签 + 目录 + 底部「开始阅读」
3. 阅读页：分页正文 + 点击呼出工具栏 + 上一章/下一章 + 字号/行距/底色 + 进度保存
4. 我的页：小说 / 短剧两块镜像面板（悬浮按钮或左右滑动切换；切换按标题/最近/书架三块 0/100/200ms 阶梯延迟）- 小说侧 = 书架 + 最近阅读 + 右上角缓存/设置入口；短剧侧 = 收藏网格 + 最近观看（点击直接续播对应集）+ 左侧缓存/设置入口；两面板共用 `PanelShell`，设置入口只有一枚、与缓存入口成组随面板在屏幕内左右移动
5. 设置页：主题色（预设 + HSV 自定义取色，全站生效并持久化）+ 存储占用与清理（离线缓存提示去「我的 → 缓存」页处理）
6. 缓存中心：我的右下角悬浮按钮进入；小说/短剧分区列出下载中/排队中/已下载，进度条 + 实时网速，暂停/继续/重试/取消排队，M3 删除与按区清空（确认框），点条目 Hero 进详情

不在本期范围：听书、漫画、评论、段评、登录。
