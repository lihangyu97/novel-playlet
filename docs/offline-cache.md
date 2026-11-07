# 离线缓存（小说 / 短剧）：方案与实施计划

> 分支：`feat/lhy/offline-cache`（从 `main` 切出）
> 状态：**已实现**（M0 存储/下载引擎、M1 小说链路、M2 短剧链路；M3 真机验收与打磨见 §14）。
> 目标：小说按「整本」、短剧按「整剧」一键下载到两个**独立、只手动清理**的离线区；
> 断网可读 / 可看；与现有自动缓存完全隔离。
> 本文只记录决策与路径，不含实现代码。

## 0. 决策记录

| # | 问题 | 结论 |
|---|---|---|
| 1 | 短剧离线是否保持 CENC 密文 | **不保持，存明文 mp4**（"能看就行"）。播放用 `VideoPlayerController.file`，不再走回环解密 |
| 2 | 短剧下载粒度 | **整剧一键下载**，不做选集多选 |
| 3 | 小说下载粒度 | **整本下载**（不做阅读器的 20/50/100 章预设，后续需要再说） |
| 4 | 容量上限 | 小说 **1 GiB**、短剧 **3 GiB**（软上限，超限阻止新任务并引导清理） |
| 5 | 清理入口 | 「设置 → 存储」下新增两个独立区块 + 管理页；「清理缓存」不碰离线区 |

补充假设（实现时按此执行，若要改再说）：

- 下载期间**保持 App 在前台**（iOS 后台下载不做，切后台自动暂停、回前台继续）；
- 不做系统剩余空间检查（P2 可选，需要加一个原生 MethodChannel）；
- 进度以「章 / 集」为粒度，字节进度在集内展示；不中断字节级续传；
- 下线内容**明文落盘**（小说正文与现在自动层一致；短剧按决策 1）。

> **关于"已缓存的短剧切换时还要不要准备播放"**：不用。离线集是本地明文 mp4，
> 播放器直接用 `VideoPlayerController.file` 打开，没有"内核下载整集 → 返回
> `/src` 地址 → 回环解密"这段准备过程；切到已缓存集只重建一个本地播放器
> （AVPlayer 初始化，百毫秒级），不联网、不转圈。未缓存的集仍走现有流程。

## 1. 目标 / 非目标

**目标**

- 小说：整本下载正文 + 目录 + 书名封面；断网从离线区进阅读、切章；
- 短剧：整剧下载全部集（明文 mp4）+ 剧名封面/选集信息；断网从离线区选集播放；
- 两个离线区独立统计、独立删除、独立清空，**永不自动清理**；
- 下载任务可暂停/继续/取消，杀进程后能从缺口续传（按章/集粒度）；
- 现有「自动加速缓存」行为不变。

**非目标（本期不做）**

- iOS 后台下载 / 后台任务（切后台即暂停）；
- 字节级断点续传（半集/半章重下）；
- 用户自选清晰度、选集下载、区间下载；
- 漫画/插图、听书离线；
- 离线内容加密（明文落盘，iCloud 备份排除列为 P2）；
- 系统剩余空间预检（P2，需要原生 MethodChannel）。

## 2. 现状：现有缓存全是自动层，不能当离线

| 缓存 | 位置 | 自动策略 | 「设置 → 清理」会清 |
|---|---|---|---|
| 封面图 | `Caches/libCachedImageData/` + 索引 | 7 天 stale、最多 120 个对象、启动时 >40MB 裁到 25MB | 会 |
| 章节正文（加速层） | `Application Support/reader_chapters/` | 最多 300 个文件、按 mtime 淘汰；7 天标记 stale（先展示再后台刷新） | 会 |
| 视频临时缓存 | `Application Support/backend/src/`（CENC 密文 + `.key`） | 总预算 128MB，异步按最旧淘汰 | 会 |
| 设备池/配置 | `backend/config/` | 不是缓存 | 不会 |

结论：离线必须新增 **pinned 层**，与上述目录物理隔离。

## 3. 两层架构与隔离不变式

```
自动加速层（现状不动）                    离线 pinned 层（新增）
reader_chapters/            ┌──────►  Application Support/offline/novel/
backend/src/                │ 互不影响  Application Support/offline/video/
Caches/封面缓存             └──────►  （只手动清理）
```

不变式（代码注释 + 测试锁住）：

1. 离线区不参与任何自动淘汰、TTL、体积裁剪；
2. 「设置 → 存储 → 清理缓存」只清自动层，**永不删除**离线区（`AppCache` 的清理列表显式排除）；
3. 离线区只能由用户显式删除（单条 / 清空该区）；删除前先取消该书/该剧进行中的任务；
4. 小说、短剧两块离线区各自独立：目录、manifest、体积统计、清空按钮互不串。

读/看路径统一为：**offline → 自动缓存 → 网络**。

## 4. 存储设计

### 4.1 目录布局

```
<Application Support>/offline/
  novel/
    <bookKey>/
      book.json                 # 书级 manifest（详见 4.3）
      <chapterKey>.json         # 每章正文（与自动层同一 JSON 结构）
  video/
    <seriesKey>/
      series.json               # 剧级 manifest（详见 4.3）
      <episodeKey>.mp4          # 明文 mp4（决策 1）
      [cover.jpg]               # 可选：下载时顺带存的封面（失败不阻断）
```

- `bookKey` / `chapterKey` / `seriesKey` / `episodeKey`：沿用
  `reader_chapter_cache.dart` 的 Base64URL 编码（去掉 `=`），避免 id 里的 `/`、`:` 变路径。
- 写入一律「临时文件 + rename」原子落盘；读取遇到损坏/半截文件直接删掉当 miss（自愈）。
- 无 manifest 的孤立目录：进入缓存管理页时整体清理（崩溃残留）。

### 4.2 章节文件 / 剧集文件

- 章节 JSON 与 `ReaderChapterCache` 完全同构：`{id,title,paragraphs,fetchedAt}`，正文明文。
- 剧集：明文 `.mp4`；manifest 记录每集字节数与是否已缓存。
- 下载中的文件：`*.part`（章节 JSON 与 mp4 同理），完成后 rename；启动时清理残留 `.part`。

### 4.3 manifest

`novel/<bookKey>/book.json`

```json
{
  "schema": 1,
  "kind": "novel",
  "bookId": "…",
  "title": "…",
  "cover": "https://…",
  "chapters": [{ "id": "…", "title": "…", "volumeName": "…", "index": 0 }],
  "completed": 320,
  "total": 1024,
  "bytes": 4718592,
  "createdAt": 1730800000000,
  "updatedAt": 1730800000000
}
```

`video/<seriesKey>/series.json`

```json
{
  "schema": 1,
  "kind": "video",
  "seriesId": "…",
  "title": "…",
  "cover": "https://…",
  "episodes": [{ "id": "…", "title": "第1集", "index": 0, "bytes": 0, "cached": false }],
  "completed": 12,
  "total": 40,
  "bytes": 314572800,
  "createdAt": 1730800000000,
  "updatedAt": 1730800000000
}
```

写入时机（避免每下 1 章/集重写整份 JSON）：

- 开始任务时写一次完整 `chapters/episodes` 列表 + 元信息；
- 下载过程中进度只写内存，**暂停 / 完成 / 取消 / 每 30s** 落一次 `completed/bytes`（防抖）；
- 恢复时以「文件是否存在」为准扫一遍校正 manifest（`completed` 偏小没关系）。

### 4.4 容量与统计

- 软上限：小说 1 GiB、短剧 3 GiB（常量，`OfflineSeriesStore.capBytes` 可注入便于测试）。
  - 小说：开始前按「已用 + 缺失章数 × 15KB」估算，超限阻止并引导清理；
  - 短剧：单集体积差异大（几十 MB 到几百 MB），**不能按集数估算**（40 集 × 150MB
    会误判超 3GiB 直接拒绝）。改为只在「区已满」时拒绝开始，下载过程中逐集检查：
    到上限就暂停并提示清理，允许当前这一集把区间小幅顶过上限。
- 统计：`book.json`/`series.json` 的 `bytes` 之和（列表页不扫盘；进入管理页时后台扫盘校正一次）。
- 体积展示格式沿用设置页的「xx MB / xx GB」。

## 5. 小说离线（整本）

沿用 `feat/lhy/novel-cache` 分支 [docs/novel-cache.md](novel-cache.md) 的核心决策，按本期范围收窄：

- **只做整本**：详情页「缓存整本」一键；从第一章扫到末章，跳过已缓存章；已部分缓存时按钮变「继续缓存」。
- 下载：`/api/v1/chapters/batch?item_ids=…`（20 章/批，内核已有，**不需要改 Rust**）；整批失败或某章未解密/空正文时回退单章 `/api/v1/chapters/{id}/novel`；单章失败记入 `failedIds` 不中断整本。
- 进度：按章推进，显示「已缓存 320/1024 章 · 4.8 MB」。
- 阅读链路（离线优先）：
  1. 有 `book.json` → 立即用本地目录进阅读页（不再等 `api.directory()`）；
  2. 正文读取顺序 offline → 自动缓存 → 网络；
  3. 在线时后台静默刷新目录并替换（按 `chapterId` 保持当前章）；断网时保持本地目录。
- 详情页：网络失败时回退 manifest（书名/封面/目录），离线也能从书架进详情。
- 目录/正文明文落盘（与自动层一致）。

## 6. 短剧离线（整剧、明文）

### 6.1 下载流程（不改 Rust）

内核 `videoSource` 会把整集 CENC 文件下载进临时缓存并返回 `/src/<id>.mp4`；
`/src` 回环对**该文件**按 Range 解密输出明文。离线下载就是把这个明文流落盘：

```
对每一集（顺序，跳过已缓存）：
  1) api.videoSource(episodeId)                  // 内核下载整集密文到临时缓存，返回绝对 /src 地址
  2) HttpClient GET <source.url>                 // 回环输出明文，流式写入 offline/video/<seriesKey>/<episodeKey>.mp4.part
     - 进度 = 已接收字节 / content-length
     - 失败：删 .part，重试 1 次
  3) .part → rename 成 .mp4                     // 原子落盘
  4) 更新内存进度，每 30s/暂停/完成落一次 manifest
```

- 临时缓存的 128MB 预算由内核自动淘汰，两段式下载的峰值磁盘 ≈ 2×单集；
  稳态只剩离线区一份（临时缓存会被自动清掉，这正是两层分离的意义）。
- 已缓存集跳过，不做重复下载；支持中途取消（删 `.part`，已完成的集保留）。
- 失败：单集重试 1 次；连续 3 集失败 → 暂停任务并提示「网络异常」。
- 不传 `refresh=1`（已缓存集不需要重新取流；坏文件的重下由失败重试覆盖）。

### 6.2 播放链路（离线优先）

`video_player_page._open(index)` 改为：

```
if (offlineSeriesStore.hasEpisode(seriesId, episode.id)) {
  controller = VideoPlayerController.file(File(offlinePath));   // 秒开，无准备阶段
} else {
  source = await api.videoSource(...);                          // 现有流程（准备中）
  controller = VideoPlayerController.networkUrl(...);
}
```

- **已缓存集切换无「准备播放」**：不请求内核、不联网、不走回环；
- 未缓存集保持现有行为（含失败原因/重试）；离线 + 未缓存 → 明确提示「该集未缓存」；
- 详情页选集：网络失败时用 `series.json` 的剧名/封面/选集兜底，已缓存集打「离线」角标（P2 项，可延后）。

## 7. 下载引擎（小说 / 短剧共用）

- **单任务队列**：同一时刻只跑 1 个任务（不同书/剧之间排队；后启动的若已有任务则提示"当前有任务进行中"）。共用一套状态机，任务类型分 `novel` / `video`。
- 状态机：`idle → running → (paused | done | failed)`；`cancel` 保留已下载内容。
- 持久化：`SharedPreferences` 的 `offline_task_v1`（kind/id/title/status/completed/total/bytes/updatedAt），启动时恢复；`running` 恢复成 `paused` 等用户继续（避免一启动就偷偷下载）。
- 前后台：`WidgetsBindingObserver`；切后台在当前章/集结束后暂停并落盘，回前台不自动继续（弹一次提示「任务已暂停，点继续」），避免用户不知情耗流量。
- 删除互斥：删除书/剧或清空区之前先 `cancel` 对应任务，再 `remove(recursive)`；同一书/剧不允许两个任务并行。
- 弱网/断网：章/集失败按上面的重试策略；连续失败暂停并提示。
- 不新增依赖（`path_provider` + `http`? 用 `dart:io HttpClient` 即可，不引包）。

## 8. UI / 交互

### 8.1 详情页

- 底栏统一为三颗「上图标、下文字」的线条风格按钮：左「收藏/已收藏」、中间主按钮（开始阅读/继续阅读）、右「缓存/缓存中/已缓存」；左右等宽，主按钮居中。
- 缓存按钮三态（图标统一用 outlined 线条风格）：
  - `缓存`（`download_outlined`）：没有离线内容或上次任务失败，点击开始/重试整本（整剧）下载；
  - `缓存中`（`downloading_outlined`）：任务进行中/暂停，或 manifest 只完成一部分，点击进「缓存中心」；
  - `已缓存`（`download_done_outlined`）：整本/整剧已下完，点击进「缓存中心」。
- 暂停 / 继续 / 重试集中在缓存中心页（§8.4）：详情页点「缓存中」不再原地暂停，避免一个按钮承担「跳转 + 暂停」两件事。
- 下载完成/失败/超容量的提示仍由下载器侧 `SnackBar` 与缓存中心页承担；超容量时文案引导去「设置 → 存储」清理。

### 8.2 设置 → 存储

- 「自动缓存」区块维持现状（视频/封面/章节 + 清理按钮），文案补一句「清理不会删除离线缓存」。
- 新增两个独立区块（上下两块，互不影响）：
  - **离线小说**：N 本 · X MB · [管理]
  - **离线短剧**：M 部 · Y MB · [管理]

### 8.3 离线缓存管理页（两 tab：小说 / 短剧）

- 小说列表项：封面 / 书名 / 「已缓存 320/1024 章 · 4.8MB」/ 最近更新时间；
  操作：继续缓存（有缺口时）/ 删除（二次确认）。
- 短剧列表项：封面 / 剧名 / 「已缓存 12/40 集 · 300MB」/ 最近更新时间；
  操作同上。
- 顶部：本区总占用、本区上限、[清空本区]（二次确认）。
- 空态用现有 `EmptyView`；文案统一「离线缓存只在手动删除时释放」。

### 8.4 缓存中心页（我的右上角 → 下载图标）

- 入口：「我的」右上角悬浮设置按钮左侧的下载图标（两个按钮成组，随小说/短剧面板切换整体左右移动）。
- 页面按「小说」「短剧」两个分区列出**正在下载 + 已下载**条目（有内容才显示分区）：
  - 运行中：`下载中 37% · 1.2 MB/s · 152 MB` + 进度条 + 右侧暂停按钮（网速来自下载器 EMA 采样，只在运行中且 >0 时显示）；
  - 暂停 / 失败：状态 + 原因（最多两行）+ 继续/重试按钮（重启后的恢复态按 manifest 重建入参续传）；
  - 已完成：`已缓存 10/10 章 · 800 KB`（短剧用「集」）。
- 点条目与推荐列表一致：封面 Hero 飞入对应详情页（`CoverHeroTag.novel/video('cache-center', id)`）。
- 与管理页分工：缓存中心只浏览/控制下载（暂停、继续、重试），删除/清空仍在「设置 → 存储」的管理页。

## 9. 与现有缓存 / 清理的关系

- `AppCache`：新增「不碰 offline/」的显式约束（清理函数只枚举已知自动目录），并补测试；
  自动缓存的统计入口不动，设置页把离线统计单独读 `OfflineStores.stats()`。
- 阅读器自动层（`ReaderChapterCache`）：不动，继续负责 ±1 章预取与非离线阅读加速。
- 播放临时层（Rust `src/`）：不动；离线命中时播放器不再触发内核下载，反而降低临时缓存压力。
- 同一章/同一集可能 auto 与 offline 各一份：正文很小；视频离线命中后不会走临时下载。
- 升级/降级：离线目录带 `schema`，读不懂就当没有（不删文件，交给用户手动清理）。

## 10. 改动清单

**新增**

```
lib/core/storage/offline/offline_paths.dart        # 目录、key 编码、原子写、目录体积统计
lib/core/storage/offline/offline_book.dart         # OfflineBook / OfflineChapter 模型
lib/core/storage/offline/offline_book_store.dart   # 小说 manifest/章节读写/统计/删除
lib/core/storage/offline/offline_series.dart       # OfflineSeries / OfflineEpisode 模型
lib/core/storage/offline/offline_series_store.dart # 短剧 manifest/集文件读写/统计/删除
lib/features/cache/offline_task.dart               # 任务模型 + 持久化
lib/features/cache/offline_downloader.dart         # 单任务状态机：小说批次 / 短剧整剧
lib/features/cache/cache_providers.dart            # stores / downloader / 统计 providers
lib/features/cache/offline_cache_page.dart         # 管理页（小说 / 短剧两 tab）
lib/features/cache/widgets/offline_download_button.dart  # 详情页三态按钮（图标+文字）
lib/features/cache/cache_center_page.dart          # 缓存中心（我的入口：下载中/已下载 + 网速 + Hero 进详情）
lib/app/widgets/detail_icon_label_button.dart      # 详情底栏「上图标、下文字」共用按钮
test/offline_book_store_test.dart
test/offline_series_store_test.dart
test/offline_downloader_test.dart
test/ui/offline_cache_test.dart                    # 管理页（设置入口）
test/ui/cache_center_test.dart                     # 缓存中心（分区/进度/网速/暂停失败态/Hero）
```

**修改**

```
lib/data/api/api_client.dart                  # + chaptersBatch()
lib/data/models/chapter_content.dart          # + parseBatchChapterContents()
lib/features/reader/reader_controller.dart    # 离线优先 bootstrap + 正文读取顺序
lib/features/detail/detail_action_bar.dart    # 左收藏 / 中主按钮 / 右缓存（图标+文字）
lib/features/detail/detail_page.dart          # 下载状态/入口 + 收藏文案
lib/features/detail/detail_providers.dart     # 详情离线兜底
lib/features/video/video_detail_page.dart     # + 缓存整剧按钮 + 离线兜底
lib/features/video/video_detail_providers.dart
lib/features/video/video_player_page.dart     # 已缓存集用 file:// 秒开；离线未缓存提示
lib/features/mine/mine_page.dart              # 右上角缓存中心入口
lib/features/settings/settings_page.dart      # 存储区块 + 两个离线入口
lib/features/cache/offline_task.dart          # + 瞬态 speedBytesPerSecond（不持久化）
lib/app/router.dart                           # + CacheCenterRoute
lib/core/cache/app_cache.dart                 # 明确排除 offline/；统计不变
CONTRACTS.md / README.md                      # 功能表/存储约定同步
```

**不改 Rust**（短剧按决策 1 存明文）。若以后要恢复密文离线，才需要 Rust 侧离线目录 + 回环挂载。

## 11. 里程碑

| 阶段 | 内容 | 估时 |
|---|---|---|
| **M0 小说核心** | `OfflinePaths` + `OfflineBookStore` + `chaptersBatch` + `OfflineDownloader`（小说分支）+ 详情页整本下载 + 单测 | ~2d |
| **M1 小说读链路 + 管理** | 阅读页离线优先、目录兜底、设置两个区块、管理页（小说 tab）、容量上限 1GiB、与自动缓存隔离测试 | ~1–1.5d |
| **M2 短剧核心** | `OfflineSeriesStore` + 下载器视频分支（`/src` 明文落盘、进度/重试）+ 详情页整剧下载 + 播放器 `file://` 秒开 + 管理页短剧 tab + 3GiB 上限 | ~2d |
| **M3 打磨** | 失败重试入口、离线角标、封面落盘、iCloud 备份排除（P2）、真机验收清单、文档同步 | ~1d |

## 12. 验收清单

- [ ] 小说：真机整本 1000+ 章下载完成，进度实时，可暂停/继续/取消，退出页面任务不停
- [ ] 小说：杀 App 后重进，已下载章保留、任务可继续且不重复下载
- [ ] 小说：飞行模式 → 缓存管理页进阅读 → 上一章/下一章/目录跳章全部可用
- [ ] 短剧：整剧下载完成；**已缓存集切换秒开（无"准备播放"等待、无网络）**
- [ ] 短剧：飞行模式 → 详情/管理页选集 → 播放、上下集切换可用；未缓存集有明确提示
- [ ] 两个离线区独立：小说清空不影响短剧，反之亦然
- [ ] 「清理缓存」后离线区文件仍在（测试断言 + 真机验证）
- [ ] 超过 1GiB / 3GiB 时阻止新任务并引导清理；写入失败（磁盘满）时暂停并提示
- [ ] 删除进行中的书/剧：任务先取消，不产生孤立文件
- [ ] 现有阅读加速缓存、播放临时缓存行为不回归；`flutter test` / `flutter analyze` / goldens 全绿

## 13. 风险与取舍

| 风险 | 处理 |
|---|---|
| 明文档落盘（内容版权/隐私） | 用户明确要求"能看就行"；App 沙盒本身受 iOS 数据保护；如需加密后续再改（Rust 侧能力已有多数代码） |
| 两段式下载峰值 ≈ 2×单集 | 临时缓存本就会自动淘汰，稳态只有离线一份；大集下载时提示保持前台 |
| 离线命中的视频不再触发内核流程 | 播放器需分别处理 `file://` 与 loopback 两路；失败提示区分"未缓存/文件损坏/其他" |
| 单任务串行（整剧排队） | 符合"点一次就走开"的心智；不做并发下载，避免设备池/风控和磁盘压力 |
| 前台才能下载 | 明示文案；切后台暂停、回前台提示继续（不做后台下载） |
| 系统空间不足 | 本期靠写入失败兜底；P2 加 MethodChannel 预检（iOS `volumeAvailableCapacityForImportantUsage`） |
| iCloud 备份占用 | P2 加 `NSURLIsExcludedFromBackupKey`（需要原生代码或现有依赖的 API） |

## 14. 落地记录（2026-11-06）

### 14.1 实际文件

**存储层**：`lib/core/storage/offline/offline_paths.dart`（目录/Base64URL key/原子写/目录统计）、
`offline_book.dart` + `offline_book_store.dart`、`offline_series.dart` + `offline_series_store.dart`

**下载引擎**：`lib/features/cache/offline_task.dart`（任务模型 + `offline_task_v1` 持久化）、
`offline_downloader.dart`（单任务状态机：小说 20 章/批 + 单章回退；短剧逐集 `videoSource` →
回环 `/src` 明文流 → `.part` → `commitEpisode`；pause/resume/cancel/clearFor；前后台暂停；
额度上限；manifest 节流）、`cache_providers.dart`、`widgets/offline_download_button.dart`

**页面**：`lib/features/cache/offline_cache_page.dart`（管理页两 tab）、
`lib/features/cache/cache_center_page.dart`（我的入口的缓存中心：下载中/已下载 + 进度/网速 + Hero 进详情）、
`lib/app/widgets/detail_icon_label_button.dart`（详情底栏共用按钮）、
`lib/features/settings/settings_page.dart`（存储 + 两个离线区块）、
`lib/features/detail/*`（详情离线兜底 + 底栏按钮）、
`lib/features/reader/reader_controller.dart`（offline → 自动缓存 → 网络的读链路）、
`lib/features/video/offline_playback.dart` + `video_player_page.dart`（已缓存集 `file://` 秒开）、
`video_detail_page.dart` / `video_detail_providers.dart`（整剧下载 + 详情离线兜底）、
`lib/app/router.dart`（`OfflineCacheRoute`）、`lib/core/cache/app_cache.dart`（离线区不参与清理的显式约束）

**测试**：`test/offline_book_store_test.dart`、`test/offline_series_store_test.dart`、
`test/offline_downloader_test.dart`、`test/api_batch_test.dart`、`test/reader_offline_test.dart`、
`test/detail_offline_test.dart`、`test/offline_playback_test.dart`、`test/ui/offline_cache_test.dart`、
`test/ui/cache_center_test.dart`；
goldens 更新 `detail.png` / `video_detail_episodes.png`（底栏新增按钮，正文 0 像素变化）、
`settings*.png`（新增离线区块）。

### 14.2 与本文方案的偏差（均为实现时的收敛，非遗漏）

1. **小说只做整本下载**：按决策去掉阅读器的 20/50/100 章预设；「继续缓存」按 manifest 缺口续传。
2. **短剧 API 名称**：`startVideoSeries` 的 `items` 参数叫 `episodes`（与页面模型一致）；短剧落盘用
   `partFile()` → 流式写 → `commitEpisode()`（不先读进内存）。
3. **单任务不排队**：已有任务时后启动的抛 `OfflineTaskBusyException`，由按钮/UI 提示
   「当前已有下载任务」；不实现队列排队。
4. **离线判定**：项目没有 connectivity 依赖，短剧「未缓存 + 离线」只能从取流失败特征推断
   （timeout / Socket 类 / unknown+连接类消息）；网络在线但上游超时也会落到「该集未离线缓存」
   文案，属可接受的语义偏差。
5. **详情离线兜底字段**：小说只回退书名/封面/目录，短剧回退剧名/封面/选集；简介、标签、评分等
   不在 manifest 里（离线详情呈现精简形态）。
6. **`pruneOrphans()` / `cleanupPartFiles()`**：进入管理页时做一次自愈；下载器启动时清理残留 `.part`。
7. **封面**：manifest 只存封面 URL，下载时未额外落盘封面文件（离线管理列表的封面可能显示占位块；
   如需离线缩略图可后续在下载时顺带保存，属 M3/P2）。

### 14.3 验收状态

- 自动化门禁：`dart format` / `flutter analyze --fatal-infos` / `flutter test`（**218 passed / 1 skipped**，
  含 21 张 golden 与新增 51+ 条离线用例）、`cargo` 侧本轮未改。
- 真机验收（M3）：按 §12 清单在 iPhone 13 上过一遍——整本下载/暂停/续传/杀进程恢复、
  飞行模式阅读与选集播放、已缓存短剧切集秒开、离线区独立清空、清理自动缓存不影响离线区。

### 14.4 迭代：详情底栏统一 + 缓存中心（2026-11-07）

- **详情底栏改版**：左右两个入口改成与「收藏」同一套 outlined 线条风格 + 「上图标、下文字」；
  文案 `收藏/已收藏`、`缓存/缓存中/已缓存`。缓存三态改为：`缓存` → 开始下载；
  `缓存中/已缓存` → 进缓存中心（暂停/继续/重试集中到那里）。
- **缓存中心页**：我的右上角新增下载图标入口；分「小说 / 短剧」列出下载中 + 已下载，展示
  进度条与实时网速（`OfflineTask.speedBytesPerSecond`，下载器按累计字节差 + EMA 采样，仅进程内有效），
  点条目 Hero 进详情。删除/清空仍走设置里的管理页。
- **验证**：`dart format` / `flutter analyze --fatal-infos` 干净；`flutter test` **233 passed / 1 skipped**
  （golden 22 张，新增 `cache_center.png`，更新 `detail.png` / `video_detail_episodes.png` / `mine_*.png` / `home_mine.png`）；
  真机（iPhone 13）按新底栏与缓存中心入口安装验收。
