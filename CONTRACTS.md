# novel-playlet 开发契约（页面开发必读）

## 现在什么已经就绪

- Flutter 工程（iOS-only 目标，但不要改 `ios/` 与 `pubspec.yaml`）
- Rust 内核 `rust/` 已完整拷入，FRB 绑定在 `lib/src/rust/`（**自动生成，不要手改**）
- 启动链：`lib/main.dart → BootstrapGate → BackendService.start() → Rust init`
- 业务接口：`lib/data/api/api_client.dart`（已封装 recommend / search / detail / directory / chapter）
- 模型：`lib/data/models/`（NovelItem、BookDetail、Chapter、ChapterContent、json_utils）
- 本地存储：`lib/core/storage/reading_store.dart`（书架、阅读进度、最近阅读）
- 主题：`lib/app/theme/app_theme.dart`（含 `ReaderPaper` 阅读底色）
- 共享组件：`lib/app/widgets/`（NovelCover、NovelGridCard、NovelListTile、LoadingView、ErrorView、EmptyView）
- 路由：`lib/app/router.dart`（`AppRoutes.detail` / `AppRoutes.reader` + `DetailArgs` / `ReaderArgs`）
- providers：`lib/app/providers.dart`（`apiClientProvider`、`readingStoreProvider`）
- ProviderScope 已在 `main.dart` 里，页面直接用 `ConsumerWidget` / `ConsumerStatefulWidget`

**当前 `lib/features/*/` 里是占位页，要由你整页替换。**

## 硬性规则

1. **只改自己 feature 目录里的文件**（见各自任务说明）。共享文件（`lib/app/**`、`lib/data/**`、`lib/core/**`、`lib/src/rust/**`、`rust/`、`ios/`、`pubspec.yaml`）一律不要改。缺共享组件就在自己的目录里写。
2. **不要新增依赖。** 只用 pubspec 里现有的包（flutter_riverpod、cached_network_image、html、shared_preferences、flutter_secure_storage、path_provider、video_player）。`video_player` 是视频域专用：只允许 `lib/features/video/` 使用，播放器细节见 `docs/video-playback.md`。
3. **不要跑 `flutter build` / `flutter run`**（很慢，由 Lead 统一验证）。用 `flutter analyze lib/features/<你的域>` 自检，必须 0 error 0 warning。
4. UI 文案用中文；注释写"为什么"，不要写"做了什么"。
5. 只用 Material 3 + `Theme.of(context).colorScheme`，不要硬编码颜色（阅读页底色用 `ReaderPaper`）。
6. 列表图片一律走 `NovelCover`（处理空 URL/失败），不要裸 `Image.network`。
7. 封面一律取缩略图：解析时用 `json_utils.dart` 的 `coverKeys`（`thumb_url` 优先），不要回退到 `detail_page_thumb_url` / `cover` 之外的大图。全 App 封面位最大 108pt 宽，详情 Hero 也只有 96×132；书架与阅读进度会把 `cover` 落盘，存大图 URL 等于永久多付带宽。

## 数据层 API（已完成，直接用）

```dart
final api = ref.watch(apiClientProvider);

// 推荐流（tab_type=2）。翻页必须回传 sessionId，否则上游会换设备导致 101116。
Future<NovelFeedPage> recommend({int offset = 0, String? sessionId});
// NovelFeedPage { List<NovelItem> items; int? nextOffset; String? sessionId; bool get hasMore }

// 搜索（tab_type=3）
Future<NovelFeedPage> search(String query, {int offset = 0});

Future<BookDetail> bookDetail(String bookId);
Future<List<Chapter>> directory(String bookId);           // 已摊平，Chapter{id,title,volumeName,index}
Future<ChapterContent> chapter(String itemId, {String title = ''});
// ChapterContent { id, title, List<String> paragraphs }
// 抛 ApiException（message 可直接展示）
```

`NovelItem`：`id / title / cover / author / intro / category / wordCount / score / lastChapter`，`isValid` 表示可展示。
`BookDetail`：`bookId / title / cover / author / abstract / category / creationStatus(0连载 1完结 -1未知) / wordNumber / serialCount / readCount / score / tags / lastChapterTitle`，另有 `statusLabel / wordLabel / metaParts`。

## 本地存储 API（已完成）

```dart
final store = ref.watch(readingStoreProvider);
Future<List<NovelItem>> shelf();
Future<bool> isOnShelf(String bookId);
Future<void> addToShelf(NovelItem item);
Future<void> removeFromShelf(String bookId);
Future<void> saveProgress({required String bookId, required String bookTitle,
  required String cover, required String chapterId, required int chapterIndex});
Future<ReadingProgress?> progress(String bookId);   // chapterId / chapterIndex
Future<List<ReadingProgress>> history({int limit = 20});  // 按时间倒序
```

## 导航

```dart
Navigator.of(context).pushNamed(AppRoutes.detail,
  arguments: DetailArgs(bookId: item.id, preview: item)); // preview 可空
Navigator.of(context).pushNamed(AppRoutes.reader,
  arguments: ReaderArgs(bookId: id, bookTitle: '', cover: '', chapterId: null, chapterIndex: null));
```

## 状态管理约定

- 每个 feature 自己建 `*_provider.dart`：`AsyncNotifierProvider` / `NotifierProvider` / `FutureProvider.family`，**不要**把状态塞进页面 `setState`（纯 UI 动画状态除外）。
- 页面 = `ConsumerWidget`/`ConsumerStatefulWidget`，只做布局与交互，不直接 new ApiClient。
- 下拉刷新 → `ref.invalidate(provider)` 或控制器 `refresh()`。
- 加载/错误/空态统一用 `LoadingView` / `ErrorView(message, onRetry)` / `EmptyView`。

## 页面清单（本期范围）

1. 推荐页：顶部搜索输入框 + 推荐列表（两 tab 里的第一个）
2. 详情页：封面/书名/作者/分类/状态/字数/简介/标签 + 目录 + 底部「开始阅读」
3. 阅读页：分页正文 + 点击呼出工具栏 + 上一章/下一章 + 字号/行距/底色 + 进度保存
4. 我的页：书架 + 最近阅读（两个 tab 里的第二个）

不在本期范围：离线下载、听书、漫画、短剧、评论、段评、登录、设置页。
