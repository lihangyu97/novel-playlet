# 离线缓存（小说 / 短剧）：方案与实施计划

> 分支：`feat/lhy/offline-cache`（从 `main` 切出）
> 状态：方案定稿，待实现。
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

- 软上限：小说 1 GiB、短剧 3 GiB（常量）。
  开始新任务前估算 `本区已用 + 待下载量`，超限则阻止并引导去管理页清理。
  单个任务超过上限直接拒绝（例如某剧总集数太大）。
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

- 小说详情底部操作栏：新增「缓存整本」按钮（三态：未缓存 / 进行中（环形进度，点击暂停/继续）/ 已缓存（点击进管理页））。
- 短剧详情底部操作栏：新增「缓存整剧」按钮，状态同上。
- 下载完成：`SnackBar`「《书名》缓存完成，共 N 章」/「《剧名》缓存完成，共 N 集」；部分失败给「重试失败章/集」。
- 超容量：弹窗提示本区已用/上限，按钮跳「设置 → 存储 → 离线缓存」管理页。

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
- 我的页可以放一行汇总入口（可选，P2）。

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
lib/features/cache/widgets/offline_download_button.dart  # 详情页三态按钮
test/offline_book_store_test.dart
test/offline_series_store_test.dart
test/offline_downloader_test.dart
test/ui/offline_cache_test.dart                    # 设置区块 / 管理页 / 按钮态（golden 可选）
```

**修改**

```
lib/data/api/api_client.dart                  # + chaptersBatch()
lib/data/models/chapter_content.dart          # + parseBatchChapterContents()
lib/features/reader/reader_controller.dart    # 离线优先 bootstrap + 正文读取顺序
lib/features/detail/detail_action_bar.dart    # + 缓存整本按钮
lib/features/detail/detail_page.dart          # 下载状态/入口
lib/features/detail/detail_providers.dart     # 详情离线兜底
lib/features/video/video_detail_page.dart     # + 缓存整剧按钮 + 离线兜底
lib/features/video/video_detail_providers.dart
lib/features/video/video_player_page.dart     # 已缓存集用 file:// 秒开；离线未缓存提示
lib/features/settings/settings_page.dart      # 存储区块 + 两个离线入口
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
