# 小说缓存（离线下载）：方案与实施计划

> 分支：`feat/lhy/novel-cache`（从 `main` 切出）
> 状态：方案，未实现。
> 目标：整本 / 批量缓存正文与目录，断网可读；缓存可查看、可暂停续传、可删除。
> 本文只记录决策与路径，不含实现代码。

## 1. 现状：已经有的和缺的

### 1.1 已经有的

| 能力 | 位置 | 关键参数 |
|---|---|---|
| 单章正文落盘缓存（自动层） | `lib/features/reader/reader_chapter_cache.dart:31` | 最多 300 个文件、内存 LRU 8 章、7 天 stale、mtime 淘汰 |
| 阅读时先缓存后网络 | `lib/features/reader/reader_controller.dart:271-300` | 命中不进 loading；stale 先展示再后台刷新 |
| 相邻章静默预取 | `lib/features/reader/reader_controller.dart:312-380` | 只预取 ±1 章，队列上限 4，并发 1 |
| 内核已支持章节批量接口 | `rust/src/endpoints/router.rs:65`、`rust/src/endpoints/content.rs:136-208` | `/api/v1/chapters/batch?item_ids=a,b,c`，一次最多未知，逐章解密 |
| 内核已有章节全量接口 | `rust/src/endpoints/full.rs:41-153` | `/api/v1/chapters/full?book_id=…&item_ids=…`，单次上限 3000 |
| 封面图磁盘缓存 | `lib/core/cache/app_image_cache.dart` | 7 天 / 120 个对象 / 40MB 上限 |

### 1.2 缺口（也就是这次要做的事）

1. **整本缓存会被自动清掉**：自动层按 mtime 只留 300 个文件，整本 1000+ 章下不完就被淘汰。
2. **没有下载任务**：没有进度、暂停/继续/取消、失败重试；退出页面就断了。
3. **目录不缓存**：`_bootstrap` 必须先 `api.directory()`（`reader_controller.dart:152`），断网时阅读页直接报错，已缓存的正文根本进不去。
4. **没有管理入口**：看不到缓存了哪些书、占多少空间，也没法删。

结论：这次不是"从零加缓存"，而是在现有"加速缓存（auto）"之外加一层 **"离线缓存（pinned）"**，并补齐任务、管理、离线链路。

## 2. 关键决策（先看这个）

| # | 决策 | 结论 | 理由 |
|---|---|---|---|
| 1 | 改造 vs 新增 | **新增 `OfflineBookStore`，现有 `ReaderChapterCache` 不动** | 自动层 300 文件/7 天语义已经稳定；离线层需要"永不淘汰 + 按书删除"，混在一起容易把两边都改坏。读路径改成 `offline → auto → network`，风险隔离。 |
| 2 | 存储选型 | **文件系统：每书一个目录 + `book.json` + 每章一个 JSON** | 不引新依赖（Hive/SQLite 都能做，但本仓库 iOS 构建已够脆弱）；按书删目录 = 一次 `remove(recursive)`，统计、清理都简单；文本量小（见 §3.5）。 |
| 3 | 下载接口 | **优先 `/api/v1/chapters/batch`，20 章/批；失败章回退单章 `/api/v1/chapters/{id}/novel`** | 1000 章从 1000 次签名请求降到 ~50 次，显著降低 101116/风控与总耗时。内核已实现，**不需要改 Rust**。 |
| 4 | 并发 | **批次串行（1 并发），批间 200ms** | 设备池/签名接口对突发并发敏感，阅读预取的并发也是 1。慢一点换稳定。 |
| 5 | 任务生命周期 | **进程级单任务 + SharedPreferences 持久化；前台下载，切后台暂停，回前台继续** | 不引后台下载依赖（iOS 需 URLSession background + 原生代码）。用户下载期间保持 App 在前台即可。 |
| 6 | 离线进入阅读 | **offline-first**：有 `book.json` 就先用本地目录进阅读页，网络成功时后台静默刷新目录 | 断网时不必等 `api.directory()` 20s 超时才失败；在线时目录最多旧几秒，无感。 |
| 7 | 容量 | **auto 层不变（300 文件）；offline 层 soft cap 1 GiB，超限阻止新任务并引导清理** | 1 章约 8–20KB → 1GiB ≈ 5–10 万章；所有用户主动发起的下载（整本 / 20/50/100 预设）都进 offline 层、不自动淘汰。fqapp 只 pin"整本"、预设批仍走自动预算，这里统一处理更符合"我点了缓存就该留下"的直觉。 |
| 8 | 明确不做 | iOS 后台下载、断点秒传、TXT 导出、正文加密（P2 可选）、漫画/插图缓存、多设备同步 | 与本期目标无关，且都要额外依赖或平台代码。 |
| 9 | 详情页入口 | **一键整本下载**（跳过已缓存章）；运行中点击 = 暂停/继续；已完成点击 = 管理（删除/查看）。区间缓存只在阅读器面板提供 | 对齐 fqapp 收敛后的做法，少一层弹层；iOS 用户对"下载按钮"的心智就是一个动作。 |

补充决策：

- **不加新依赖**。`path_provider` + `shared_preferences` + 现有 `html` 已够用。
- 正文**明文**落盘（与现有 auto 层一致）。iOS 默认 Data Protection 兜底；iCloud 备份排除（`NSURLIsExcludedFromBackupKey`）列为 P2。
- **不做自动清理**：offline 层只允许用户删或超限时提示，不静默淘汰。

## 3. 存储设计

### 3.1 目录结构

```
<ApplicationSupport>/novel_cache/offline/
  <bookKey>/
    book.json                  # 书级 manifest：目录 + 书名/封面 + 统计
    <chapterKey>.json          # 每章正文，与 auto 层同一 JSON 结构
```

- `bookKey` / `chapterKey`：沿用 `reader_chapter_cache.dart:209` 的 Base64URL 编码（去掉 `=`），避免 id 里的 `/`、`:` 变成路径。
- 现有 auto 层目录 `reader_chapters/` 保持不变，**不做迁移**（老缓存继续当加速层用）。

### 3.2 章节文件（与 auto 层兼容）

```json
{
  "id": "chapterId",
  "title": "第一章 …",
  "paragraphs": ["…", "…"],
  "fetchedAt": 1730800000000
}
```

- 写入方式沿用现有实现：临时文件 + `rename` 原子落盘（`reader_chapter_cache.dart:80-101`）。
- 读取时同样做宽松解析：损坏 / 半截文件直接删掉当 miss。

### 3.3 书级 manifest（`book.json`）

```json
{
  "schema": 1,
  "bookId": "…",
  "title": "…",
  "cover": "https://…",
  "chapters": [
    { "id": "…", "title": "…", "volumeName": "…", "index": 0 }
  ],
  "createdAt": 1730800000000,
  "updatedAt": 1730800000000,
  "completed": 320,
  "bytes": 4718592
}
```

写入时机（关键，避免每下 1 章重写一次上千章的 JSON）：

- **开始任务时**写一次完整 `chapters`（来自线上目录）+ 书名/封面；
- **下载过程中不写 manifest**，完成数/字节数在内存里累计；
- **暂停 / 完成 / 取消 / 每 30s** 落一次 `completed` / `bytes`（防抖）；
- 崩溃后恢复：manifest 的 `completed` 可能偏小，**以"章文件是否存在"为准**，恢复时扫一次目录校正，并补写 manifest。

### 3.4 一致性与自愈

| 场景 | 处理 |
|---|---|
| 章节 JSON 损坏 | 删除该文件，算 miss；下次下载/阅读重新拉 |
| `book.json` 损坏 | 该书从缓存列表消失；孤立章节文件由清理任务（启动时或进入缓存页时）按"无 manifest 的目录"整体删除 |
| 下载中进程被杀 | 已完成章节文件保留；manifest 的 chapters 已在，打开时按文件扫描续传 |
| 系统清理/换机 | 目录不存在 = 没缓存；不做假设，所有读取都先 `exists` |
| 线上目录变化 | 以线上目录为准重新写 `chapters`；已缓存章节按 `chapterId` 匹配保留，对不上的旧文件清理 |

### 3.5 容量与统计

- 文本体积实测预估：1 章约 8–20KB，1000 章约 10–20MB，50 本≈1GB。
- `OfflineBookStore.books()`：遍历 `offline/` 下一级目录，读 `book.json`，用 manifest 里的 `completed/bytes` 展示（扫描校正放后台，不阻塞列表）。
- `totalBytes`：各书 manifest 求和；删除单本 = `Directory.remove(recursive: true)`。
- offline soft cap：`1 GiB`（常量，先不做设置项）。开始任务前估算 `已用 + 章数 × 15KB`，超限则弹窗引导去缓存页清理。

### 3.6 为什么不直接复用/扩展 `ReaderChapterCache`

- 自动层淘汰策略是"按 mtime 只留 300 个"，离线层要求"永不淘汰"，同一套 trim 逻辑里加 pin 判断会让两边都难测；
- 自动层 key 只有 `chapterId`，离线层需要 `bookId` 维度的目录、统计、整书删除；
- 拆开后，离线链路出问题不会影响现有阅读加速。

代价是同一章可能在 auto 与 offline 各存一份（文本很小），且读路径多一次判断，可接受。

## 4. 下载引擎

### 4.1 状态机

```
idle ──start()──► running ──pause()──► paused ──resume()──► running
                    │  └──cancel()──► idle（保留已下载章节）
                    └──全部完成/无缺失──► done
```

任务对象（内存 + SharedPreferences `offline_task_v1`）：

```dart
class CacheTask {
  final String bookId;
  final int startIndex;     // 起始章（目录下标）
  final int count;          // 0 = 到最后一章
  final String status;      // running / paused
  final int completed;      // 展示用，恢复时以文件为准
  final int total;
  final int updatedAt;
}
```

同一时刻只有 1 个任务（不同书排队，后启动的替换/拒绝并提示）。

### 4.2 一批的流程

```dart
Future<void> _runBatch(List<Chapter> batch) async {
  final missing = await _store.missingChapters(bookId, batch);   // 跳过已缓存
  if (missing.isEmpty) return;
  Map<String, ChapterContent> got;
  try {
    got = await api.chaptersBatch(missing);                      // 20 章/次
  } catch (_) {
    got = {};                                                    // 整批失败 → 全部走单章兜底
  }
  for (final chapter in missing) {
    var content = got[chapter.id];
    if (content == null || content.isEmpty || _looksEncrypted(content)) {
      content = await api.chapter(chapter.id, title: chapter.title);  // 单章兜底
    }
    await _store.writeChapter(bookId, content);
    _progress.completed++;
    _notify();                                                   // 进度回调（节流）
  }
  await Future<void>.delayed(const Duration(milliseconds: 200)); // 批间礼貌间隔
}
```

- **批大小 20**：`item_ids` 约 20×20 字符，URL 可控；响应约 300KB。
- **单章兜底**必须保留：batch 端点在解密失败时不回退 full 接口（`content.rs:136-191` 与单章 `handle_single` 的行为不同），且可能夹带未解密内容。
- `_looksEncrypted`：内容里没有 `<` / 换行、长度 > 200、base64 字符集 → 判定失败，走单章接口。
- **校验**：`paragraphs` 为空直接当失败；单章超过 2MB 视为异常，跳过并记录。
- 本仓库正文解析只保留文字段落（`htmlToParagraphs` 会丢掉 `<img>`），离线正文与在线阅读完全一致，因此 **不需要 fqapp 那套插图过期/`incompleteImages` 逻辑**。
- **失败不中断整本**：该章记入 `failedIds`，继续下一章；结束提示"成功 N 章，失败 M 章，可重试"。
- **重试**：batch 失败重试 1 次（500ms 后）；单章失败重试 1 次；仍失败留给用户手动重试（只补缺失章，对齐 fqapp `test/detail_download_batch_test.dart:13-72` 的验收思路）。

### 4.3 生命周期与前后台

- `OfflineDownloader` 是进程级 Riverpod `Notifier`，页面只是监听者；退出详情页/阅读页任务继续。
- 通过 `WidgetsBindingObserver` 监听：
  - `paused / inactive` → 在当前批次结束后暂停（不中断 in-flight 请求），任务状态落盘 `paused`；
  - `resumed` → 若任务在暂停前是 running，自动继续。
- 锁屏 = 退后台 = 暂停。**文案上明确提示"缓存期间请保持 App 在前台"**，不假装支持后台。
- 断网处理：单章失败按上面的兜底逻辑重试；连续 3 章失败 → 暂停任务并提示"网络异常，已暂停"，避免空转。

### 4.4 与阅读预取的关系

- 阅读中的 ±1 预取写 auto 层；离线下载写 offline 层，互不干扰。
- 读路径 offline 命中时不再请求网络，也不会写 auto。
- 下载某书期间打开该书阅读：当前章从 offline 读；未下载的章照常网络拉取并写 auto，不阻塞下载。

### 4.5 删除与下载任务互斥

- 删除某书缓存 / 全部清空前，必须先 `cancel()` 该书的下载任务（或等当前批次结束），再 `remove(recursive)`；否则"目录被删、任务继续写"会产生孤立文件或写失败。
- 删除当前正在阅读的书：已展示的正文留在内存，可继续读本章；切章时按 miss 处理（fqapp 踩过"批次中途清目录导致后续章节写了但发现不了"，见 `test/review_fix_b02_test.dart:22-44`）。
- 同一本书不允许两条批次并发：所有入口（详情页、阅读器、缓存页）共用同一个进程级下载队列。

## 5. 数据层改动

### 5.1 新增批量接口（Dart 侧，无 Rust 改动）

```dart
/// 一次取多章正文。失败/未解密/空正文的章节不出现在结果里。
Future<Map<String, ChapterContent>> chaptersBatch(
  List<Chapter> chapters, {
  Duration timeout = const Duration(seconds: 40),
});
```

- 请求：`GET /api/v1/chapters/batch?item_ids=<逗号分隔>`（路由见 `rust/src/endpoints/router.rs:65-70`）。
- 响应：`data` 是 `{ itemId: { content, title, … } }`，`content` 已被内核解密成 HTML。
- 解析：新增 `parseBatchChapterContents` 放 `lib/data/models/chapter_content.dart`，复用 `htmlToParagraphs` 与 `_stripLeadingTitle`；不要求 `content_decrypted` 字段（batch 响应没有这个标记）。
- 现有 `chapter()` 不动，继续作为单章兜底。

### 5.2 目录 / 详情离线化

- 不新增 Rust 接口：manifest 直接存 `Chapter` 列表和书名/封面。
- 阅读页 bootstrap 改为：有 manifest → 立即用本地目录渲染，同时后台请求线上目录，成功后替换（按 `chapterId` 保持当前章）。
- 详情页 P1：`detailBundleProvider` 网络失败时回退 manifest（标题/封面/目录），离线也能从书架进详情。

### 5.3 可测试性：接口 + 注入

- 定义 `abstract interface class OfflineChapterCache`（`book / writeChapter / missingChapters / books / deleteBook / clearAll`），`OfflineBookStore` 是实现；`OfflineDownloader` 只依赖接口。
- 测试注入内存实现（对齐 fqapp 的 `ChapterCache` 接口 + `MemoryChapterCache`，`lib/services/chapter_cache_store.dart:11-45`、`test/support/fakes.dart`），这样下载器的续传/取消/失败用例不碰磁盘。
- 存储测试用临时目录注入（构造函数支持 `Future<Directory> Function()`，现有 auto 层已是这种写法）。

### 5.4 新增依赖

无。

## 6. UI / 交互

### 6.1 详情页

- `DetailActionBar`（`lib/features/detail/detail_action_bar.dart:9`）左侧加**下载按钮**（第三个按钮，图标 + 状态），三态：
  - 未缓存 / 部分缓存：下载图标，**点击直接整本下载**（从第一章扫到末章，跳过已缓存章；部分缓存时文案"继续缓存"）；
  - 下载中：环形进度 + 百分比，点击暂停/继续；
  - 已缓存：勾选图标，点击弹管理菜单（删除缓存 / 查看缓存）。
- 不额外弹"整本 / 续读位置 / 缺失章"选项层：区间缓存放阅读器面板（§6.2），详情页只保留"整本"一个心智。
- 目录区可选：已缓存/未缓存章标记（P2）。

### 6.2 阅读器

- `ReaderBottomBar`（`lib/features/reader/reader_widgets.dart:168`）加第 5 个按钮「缓存」（5 等分在 iPhone 上仍够宽）。
- 打开「缓存」弹层（沿用阅读设置弹层的配色规则）：
  - 预设：后续 20 / 50 / 100 章、剩余全部；
  - 进度条 + 暂停/继续/取消；
  - 已缓存章数 / 该书占用体积；
  - 「删除本书缓存」（二次确认）。
- 目录弹层逐章打「已缓存」小勾（成本低、感知强，fqapp 同款 `lib/widgets/reader/reader_directory_sheet.dart:385-394`），P2 再做。
- 不在阅读页做"每章缓存状态"强提醒，避免打断阅读。

### 6.3 我的页

- 在"最近阅读"和"我的书架"之间加一行入口：**离线缓存 · N 本 · X MB**（对齐 `mine_page.dart` 现有 section header 风格）。

### 6.4 缓存管理页 `CachedBooksPage`

- 列表：封面 / 书名 / "已缓存 320/1024 章 · 4.8MB" / 最近更新时间；按最近使用排序。
- 点击 → 带进度直接进阅读页（`ReadingStore.progress` 优先，否则第 1 章；章 id 对不上时按 chapterIndex 兜底）。
- 行内操作：继续缓存（有未完成章节时）/ 删除（二次确认）。
- 顶部：总占用、全部删除。
- 空态：使用现有 `EmptyView`。

### 6.5 完成 / 失败反馈

- 完成：`SnackBar`「《书名》缓存完成，共 N 章」；
- 部分失败：`SnackBar` + 按钮「重试失败章」；
- 超容量/磁盘写失败：暂停并提示，引导到缓存管理页清理。

## 7. 改动清单

**新增**

```
lib/core/storage/offline_book_store.dart      # 目录/manifest/章节读写/统计/删除
lib/core/storage/offline_book.dart            # OfflineBook / OfflineBookSummary 模型
lib/features/cache/offline_downloader.dart    # 任务状态机、批次、暂停/续传、生命周期
lib/features/cache/cache_providers.dart       # store/downloader/cachedBooks providers
lib/features/cache/cached_books_page.dart     # 缓存管理页
lib/features/cache/widgets/cache_download_sheet.dart  # 详情页/阅读器共用的下载选项与进度
```

**修改**

```
lib/data/api/api_client.dart                  # + chaptersBatch
lib/data/models/chapter_content.dart          # + parseBatchChapterContents
lib/features/reader/reader_controller.dart    # offline-first 读路径 + 目录兜底
lib/features/reader/reader_page.dart          # 缓存弹层入口
lib/features/reader/reader_widgets.dart       # ReaderBottomBar +「缓存」
lib/features/detail/detail_action_bar.dart    # + 下载按钮
lib/features/detail/detail_page.dart          # 下载状态与弹层接入
lib/features/detail/detail_providers.dart     # 详情离线兜底（P1）
lib/features/mine/mine_page.dart              # 缓存入口
lib/app/router.dart                           # AppRoutes.cachedBooks
CONTRACTS.md / README.md                      # 规则与功能表同步
```

`CONTRACTS.md` 里"只改自己 feature 目录、不加依赖"是并行开发期的约束，本需求需要动 `core/`、`data/`、`reader/` 等共享层，**由 Lead 统一改并同步契约**。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M0**（核心闭环） | `OfflineBookStore` + `chaptersBatch` + `OfflineDownloader` + 详情页整本下载 | 真机整本下载 1000 章完成；杀进程后能续传；断网后从缓存页/详情页能进阅读并翻章 |
| **M1**（离线阅读链路） | 阅读页 offline-first、目录兜底、详情页兜底 | 飞行模式下：启动 → 缓存页 → 阅读 → 切章 → 退出重进，全程可用 |
| **M2**（管理 UI） | 我的入口、缓存管理页、删除/全部删除、容量上限、阅读器批量缓存 | 删除单本/全部生效；超 1GiB 阻止并提示；阅读器 20/50/100 预设可用 |
| **M3**（打磨） | 失败章重试、目录重校验、断网/弱网文案、统计准确、README/CONTRACTS | 失败率/耗时记录在案，弱网表现可接受 |

## 9. 验收清单

- [ ] 整本 1000+ 章缓存，进度实时、可暂停/继续/取消，退出页面任务不停
- [ ] 杀 App 后重进，已下载章节保留，任务可继续且不重复下载
- [ ] 飞行模式：缓存页 → 阅读 → 上一章/下一章/目录跳章全部可用
- [ ] 缓存管理页：单本/全部删除、体积统计与文件系统一致
- [ ] 失败章有明确提示，可只补失败章
- [ ] 缓存期间切后台自动暂停，回前台继续
- [ ] 现有阅读加速缓存行为不回归（`flutter test`、`flutter analyze` 通过）
- [ ] 弱网/断网/磁盘满（可用模拟器/注入故障）不产生半截可读异常

### 9.1 单测 / 组件测试（对齐 fqapp 的等价用例）

- **store**：manifest 重建、原子写半截恢复、损坏章节当 miss、删除后列表不可见、统计与文件系统一致、同章 ID 跨书不串（离线层按书目录天然隔离，仍需断言）。
- **pin/容量**：offline 章节不参与 auto 层 trim；auto 层 LRU 行为保持不变；单章超限拒绝。
- **downloader**：双击只跑一批；取消后不再落盘；从第一个缺口续传（不重下已存在章）；单章失败不中断并记录 failedIds；暂停后恢复不重复；整批失败回退单章。
- **reader**：有 manifest 且无网时能进阅读并切章；在线刷新目录后当前章保持；缓存 miss + 无网的错误态可重试。
- **UI**：详情页下载按钮三态、阅读器弹层预设、缓存管理页空态/列表/删除确认（沿用 `test/ui_preview_test.dart` 的 fake transport + golden 方式）。
- **live probe**：`/chapters/batch` 1/10/30 章，记录耗时、失败率、内容是否解密。

## 10. 风险与待验证

| 优先级 | 风险 | 验证 / 对策 |
|---|---|---|
| **P0** | `/api/v1/chapters/batch` 真实行为未验证（一次 20 章是否被接受、耗时、失败率、是否触发风控/101116） | 先在 `test/live_probe_test.dart` 增加探针：目录前 1/10/30 章分批请求，记录耗时/失败/内容是否解密；不达标就降级为"逐章 + 并发 2"，方案其余不变 |
| **P0** | batch 端点解密失败时**不会**自动回退 full（与单章不同） | 内容校验 + 单章回退，必须覆盖测试 |
| P1 | iOS 退后台即挂起，下载会停 | 前台下载 + 暂停/续传；文案明确；后台下载列为后续（需原生 URLSession） |
| P1 | 存储增长 / 用户无感占用 | 1GiB soft cap + 管理页可见；不做静默淘汰 |
| P1 | 目录/章节 id 变化导致 manifest 与线上不一致 | 在线时以线上目录为准；按 id 匹配保留；提供"重新校验"入口清理孤儿文件 |
| P2 | 明文正文 + iCloud 备份（Application Support 默认会被备份） | 缓存放 Application Support 而不是 Caches（避免被系统清理）；备份排除需原生 `NSURLIsExcludedFromBackupKey`，列为后续；正文加密（Keychain 密钥）同样后续 |
| P2 | 版权/合规 | README 现有声明需补一句"正文仅本地缓存，仅供个人学习"；不对外分发 |

**已定（2026-11-04）**：

1. **详情页一键整本下载**（跳过已缓存章）；区间缓存放阅读器面板（20/50/100/剩余全部）。
2. **offline 上限 1GiB，不做设置项**。App 目前没有设置页（README 里也是后续项），先常量；超限提示去缓存管理页清理。
3. **TXT 导出、正文加密不做本期**。都放 P2：导出涉及平台文件分享能力，加密涉及密钥生命周期，均不影响离线阅读主链路。
4. **明文落盘**（与现有 auto 层一致），目录放 Application Support；备份排除与加密后续按 P2 评估。
5. **batch 接口先探针验证**：不达标就降级"逐章 + 并发 2"，其余设计不变。

## 11. 参考

与 fqapp 的关键差异（本方案是"抄骨架 + 补短"）：

- fqapp 的下载器是**串行 for 循环：无重试、无节流、无 App 生命周期处理、任务不持久化**；"续传"= 重新点下载后从缺口跳过。本方案补齐重试/暂停续传/前后台暂停，并保留从缺口续传。
- fqapp **没有用批量章节接口**（每章一次请求）；本方案用内核已有的 `/chapters/batch` 把请求数降一个数量级（P0 待验证）。
- fqapp 用 Hive 整箱加密；本方案不引依赖，正文明文落盘，加密列为后续（接口预留）。
- fqapp 的目录与正文分箱是为了避免"打开几百 MB 箱卡 UI"；本方案天然按书分目录、每章独立文件，不存在这个问题。
- **不要复用 fqapp 的 `download_resume_store`**：那是音视频"单个大文件 `.part` + ETag"的续传模型；小说章节的续传就是"跳过已存在的章"，两套语义不能混。

fqapp（同仓库族，Android/Windows，已有完整实现）：

- `lib/services/chapter_cache_store.dart:131-160`：Hive 双 box（正文 / 目录分离）、`maxEntries=500`、`maxBytes=80MB`、pinned 不占预算
- `lib/services/chapter_cache_store.dart:326-357`：写入/合并统计/pinned 跳过 trim
- `lib/services/chapter_download.dart`：批次执行器、`pin`、进度计算
- `lib/services/chapter_download.dart:188-225`：`WholeBookDownload` 进程级协调器（跨页面续挂）
- `lib/widgets/chapter_cache_sheet.dart:64`：阅读器预设 `[20, 50, 100]` + 剩余全部
- `lib/pages/cached_books_page.dart`：缓存管理页（统计、删除、TXT 导出）
- `test/detail_download_batch_test.dart`：整本下载"从第一个缺口续传"的验收用例

novel-playlet 现状：

- `lib/features/reader/reader_chapter_cache.dart`：auto 层实现（可直接复用的编解码/原子写/淘汰逻辑）
- `lib/features/reader/reader_controller.dart:144-187, 245-380`：阅读页 bootstrap 与缓存读取/预取
- `rust/src/endpoints/router.rs:59-85`、`rust/src/endpoints/content.rs:136-208`：批量正文章节接口
- `rust/src/endpoints/full.rs:41-153, 206-227`：全量章节接口（3000 上限）
- `docs/video-playback.md`：本项目方案文档的写法与决策记录格式

## 12. 决策记录

| 日期 | 结论 |
|---|---|
| 2026-11-04 | 分支 `feat/lhy/novel-cache` 从 `main` 切出；在现有 auto 缓存外新增 offline 缓存层，不做改造 |
| 2026-11-04 | 存储走文件系统（每书一目录 + `book.json` + 每章 JSON），不引 Hive/SQLite，不加依赖 |
| 2026-11-04 | 下载优先 `/api/v1/chapters/batch`（20 章/批，单章兜底），串行 + 批间 200ms；P0 探针不达标则降级逐章 + 并发 2 |
| 2026-11-04 | 详情页一键整本下载；阅读器面板给 20/50/100/剩余全部；我的页 + 缓存管理页负责查看/删除 |
| 2026-11-04 | offline 上限 1GiB、不做设置项；用户下载的正文不自动淘汰 |
| 2026-11-04 | 前台下载 + 切后台暂停/回前台续传；iOS 后台下载、TXT 导出、正文加密均不做本期 |
| 2026-11-04 | 阅读链路 offline-first：有 `book.json` 先用本地目录进阅读，网络成功后台刷新 |
