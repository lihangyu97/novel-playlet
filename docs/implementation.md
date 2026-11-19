# novel-playlet 实现说明

> 基线：HEAD `2a2477c`（2026-11-08）。本文是当前实现的唯一说明文档，已按代码校正，
> 合并了原离线缓存、视频播放、清晰度/倍速、架构评审、书城分类、阅读分页 profile、
> Android 打包等文档的有效内容，并删掉了已过时的方案与实施过程记录。
> 代码行号会随重构漂移，引用前先 `grep -n` 核对。

---

## 1. App 是什么

一个**小说 / 短剧聚合阅读器**：内容实时来自第三方公开接口，App 自身不存任何内容。
目标平台 iOS 优先（免费 Apple ID 自签，7 天重签），Android 打包链路已打通。

页面：

- **推荐**：小红书式顶栏（整行与 tabs 同高 32pt，常驻不随列表收起）——分类 tabs（小说 / 短剧 / 漫剧，整组居中、当前分类带下划线）在左，右侧一个独立的放大镜图标（`search_rounded`，无底色，点击进独立搜索页）；顶栏没有整行搜索框、也没有缓存入口（缓存入口在我的页头）。固定顶部模块带很淡的蓝粉氛围渐变；下划线贴行底，到下方榜单区块/首屏卡片留 8pt。每个分类独立推荐流，翻页、下拉刷新、首屏不足自动补页。搜索不再内联在推荐页（搜索词不会改写推荐流）。
  推荐流是**白底不定高卡片 + 瀑布流**（`SliverMasonryGrid`）：默认双列、设置里可切三列，卡片高度由内容决定（标题 1~2 行、没有元信息就不占行），封面按内容域原生比例出图（小说 240×320、短剧/漫剧 400×571），不再统一裁成 11:8。
  首屏（含失败重试后的重新加载）不再是整屏转圈，而是铺与真卡**同列宽、同封面比例、同行高**的骨架（`recommend_skeleton.dart`）：按当前布局双列/三列铺开，标题 1 / 2 行与「是否有附加元信息」按确定性规则轮换制造高低差；骨架不可滚动、不做 shimmer（与搜索页 `CompactSkeletonRow` 同一套静态色块），数据到达后原地填色，不整屏跳版。
  首次安装的联网权限弹窗（国产 ROM 的「允许使用 WLAN 和移动数据」、iOS 的无线数据提示）会挡住第一批请求：启动闸门成功后先打一发 `ApiClient.warmUpNetwork()`（`search/cue` 小请求）把弹窗提前到启动页，而不是首页骨架后面；首屏只对**可重试**失败做两次短退避（400ms / 800ms，加首次最多 3 次请求、约 1.2s），骨架承接等待，`bad_input` / `too_large` / `device_failed` 立刻给错误页；弹窗停留超过这个窗口时，用户点完「允许」回到前台（`resumed`）会把停在错误态的那个分类首屏 invalidate 重拉一次。
  推荐卡元信息：**双列**（默认）时推荐理由做成封面左上角角标，文字区只有「标题 + 作者（短剧为「全 N 集」）左 / 热度右」一行；**三列**卡片太窄，角标放不下，理由/热度退回文字区逐行。热度 = 小说 `rank_score` / 短剧 `rec_text`（如「4691万热度」），推荐理由 = `recommend_reason_list` 第一条（小说是数组元素 `content`，如「巅峰榜No.3」；短剧是 JSON 串里的 `rec_tags[0].content` / `tag_info.text`）。**评分不进元信息行**，而是封面右上角角标（白字 + 半透明深色底 + 轻阴影，`9.3分`），小说与短剧/漫剧一致；短剧详情页也会展示星标评分。
- **排行榜**：目录取自小说首页 `rank_with_category_data`（`cell_id_str` 是榜列表 id），条目走 `/api/v1/rank/{rankId}`。上游的榜单目录把小说/短剧/漫剧放在同一份 `rank_algo_list` 里，但短剧/漫剧必须额外带 `genre_tab=4/5`（`cell_selector` 的外层分组），否则接口会按小说榜回答。首页小说/短剧/漫剧三个 tab 的瀑布流上方各有一个榜单区块，版式与搜索结果页的分类行一致：榜名（推荐榜/短剧榜/漫剧榜）在卡片外面、右侧「更多」带 `initialAlgo` 进排行榜页并自动定位；下面是 `CompactCardRow` 的一行紧凑卡（与搜索结果同款卡宽/字号，取首屏前 10、无 1/2/3 标号、横向可滑，评分走封面角标，元信息为作者/集数 + 热度；请求失败/空榜重试一次再收起，避免一次抖动让某个分类整场会话都没有榜单）；首次加载先显示同口径骨架；排行榜页二级 tab 按小说（推荐/完本/巅峰/新书）→短剧→漫剧排序、无下划线，内容区用 TabBarView 左右滑切榜；每个 tab 自己请求并 keep-alive，切回不重拉、保留滚动位置；列表行含名次、封面、标题+评分、作者/分类/热度（短剧/漫剧为分类/全N集/热度）、两行简介和题材标签，行间不画分割线，触底按 `next_offset` 翻页；条目的 book_data/video_data 由 `RankEntry` 统一，点击按 kind 进小说/短剧详情；条目行 `RankEntryRow` 与「条目 → 路由/Hero tag」的 `rankEntryRoute()` 由排行榜页与首页榜单卡片共用；列表骨架直接复用首页流的 `FeedView`/`FeedFooter`（下拉刷新、触底翻页、首屏不满自动补页、翻页失败重试与「没有更多了」文案全 App 一致），每个 tab 只保留自己的 `FeedState<RankEntry>` 与分页请求。
- **搜索页**：独立页面（推荐页顶栏搜索图标点进来）。搜索框占位轮播 cue 热词（`/api/v1/search/cue` 一次给一组词 + `rotate_interval_ms`，无词/失败回退静态提示）；**空输入提交（回车/点搜索）直接用当前占位热词搜索**并把它填回输入框（热词只是 placeholder，不是输入内容）。一次提交**搜小说 / 短剧**，从上到下 小说 / 短剧两行横滑卡片（一屏约 3.5 张），卡片复用首页同款白底卡、按屏宽缩小字号；每行独立 加载骨架（与真卡同宽同高的色块占位）/ 失败重试 / 空态，点卡片按内容域进详情。**不单列漫剧行**：漫剧没有独立搜索 tab，是借短剧搜索 tab 再按 `genre=205` 过滤的，和短剧行是同一份响应，单列会重复请求、重复展示，所以短剧行直接展示上游混排结果；视频卡不展示推荐理由（上游这个字段在搜索响应里是「漫剧」或「上新」这类角标，窄卡上挤占集数/热度），只留「全 N 集 + 热度」；v1 每个分类只取首屏一页，不接 `next_offset`。输入框为空时展示最近搜索历史（最多 10 条、去重置顶、可一键清空），点历史词直接重新搜索；历史下方是热搜榜（官方 472 榜 `/api/v1/search/hot`，最多取前 30 条（接口一次 50 条，超出截断），名次 1–3 标红、标题后展示 `display_tag` 彩色角标，右侧保留 `tag_attached` 的前缀、只把数字换算成整数 `3905w+`，点词直接搜；没有历史时热搜榜仍展示）。
- **详情**：小说与短剧共用一套「封面头 + 简介卡 + 标签」版式；小说有目录 + 书评卡片（首条 + 弹窗看全部），短剧有剧评卡片（首条 + 弹窗看全部）与选集（36 集/组）。目录卡片行间不画分割线；「查看全部」直接复用阅读器的目录弹层（`ChapterDirectorySheet`：右侧常驻可拖动滚动条、当前章左侧主色竖条 + 「读到这里」、打开时定位到进度所在章，详情页额外插卷标题）。选集集数按钮与播放页选集弹层共用 `EpisodeTile`：无描边、未选中一层淡底色、选中主色实心。底部是「收藏 / 缓存 / 播放·阅读」三颗圆形悬浮按钮（`DetailActionBar` + `DetailCircleButton`）：按钮只有图标、靠右排列、固定间距，文案只交给读屏；按钮盖在正文上方（`extendBody`），页面末尾按 `totalHeight` 留白。
- **阅读页**：`TextPainter` 真实分页、左右翻页、点击分区、工具栏（顶部「加入书架/已在书架 + 缓存小说/缓存中/已缓存」文本动作，底部目录/详情/评论/日间·夜间/设置；「详情」以无标题底部弹层打开小说详情，不画关闭叉号、不重复目录，只留收藏/缓存；左上圆角裁切内容，下滑/点遮罩关闭）、字号/行距/字重/4 种底色（色块与标题同行）、日/夜切换、段评气泡、工具栏「评论」/评论面板（只读）、目录跳章（目录弹层与详情页「查看全部」共用 `ChapterDirectorySheet`，右侧常驻可拖动滚动条）、邻章预取、进度保存。
- **播放页**：`video_player`（iOS AVPlayer / Android ExoPlayer）、1.0–3.0x 倍速、控制条自动隐藏、上下滑切集（竖向翻页）/播完自动下一集、选集弹层、横屏全屏、在线 MP4 边下边播、失败分类与「重新下载这一集」；底排左侧「选集 + 详情 + 本集评论」、中间播放/暂停、右侧「清晰度（拿得到才展示，只读）+ 倍速」；倍速**点开是贴着 chip 的小浮窗**（M3 `MenuAnchor` + `MenuItemButton`，竖排 1.0/1.25/1.5/2.0/3.0x，当前档打勾，选完即关；浮窗打开期间控制条的 3.5s 自动隐藏被冻结），不再是遮大半屏的底部弹层；收藏/缓存统一收进「详情」底部弹层（历史「最近观看」直进播放页也从这里操作；详情弹层不重复选集、无关闭叉号）。进度条左右分别显示当前时间/总时长，外沿与下方按钮、倍速 chip 对齐。收藏**只加不移**（与阅读页加入书架一致，已收藏后只读，成功不弹提示条）；缓存三态与详情页同一份 `offlineEntryStatusProvider`。
- **我的**：统一页头（图标 + 「我的」 + 合并统计 + 右上角缓存中心与设置两枚线性图标按钮（缓存在左、设置在右），固定贴顶、不随内容滚动，带一套蓝粉氛围渐变）+ 小说 / 短剧两个 tab（带下划线，当前 tab 主题色高亮且字号稍大，可点击或左右滑动切换，内容各自保活；页头到 tabs、下划线到第一个区块标题都留 8pt）；小说 tab = 书架 + 最近阅读，短剧 tab = 收藏 + 最近观看；书架/收藏与首页同款白底不定高卡片（瀑布流，小说只展示书名+作者、短剧只展示剧名+集数）。
- **缓存中心**：离线整本 / 整剧下载的进度、网速、排队、暂停/继续/删除/清空；入口在我的页头右上角「缓存」图标（在设置左边；推荐页顶栏已无缓存入口）。
- **设置**：主题色（天蓝 / 草绿 / 绯红 + 自定义取色，自定义圆点显示上次自定义色）、对话高亮（卡片右侧圆形色块打开弹层，弹层里先选样式按钮组——荧光笔 / 下划线 / 波浪线——再用 HSV 取色，示例正文按当前样式与颜色实时预览）、深浅色模式（跟随系统 / 手动）、推荐流布局（双列 / 三列，M3 按钮组 `SegmentedButton`，默认双列）、全局字重（仅 Android；阅读器默认跟随，可在阅读器内覆盖）、WebDAV 云同步（书架/收藏/阅读进度/观看进度；凭据进 Keychain/Keystore，文件按 release/beta/dev 分目录）、存储（占用明细 + 右下角**只留图标**的清理按钮 + 卡片内小字「不包括主动缓存的小说、短剧」）与「下载清晰度」（四档并进存储区块，同样是按钮组；不再单开「视频」区块）。

两个内容链路：

```text
小说：详情 → 目录 → 章节正文（缓存/网络）→ 解析 → TextPainter 分页 → 渲染
短剧：详情 → 选集 → 取流/缓存 → 回环解密 → AVPlayer/ExoPlayer 渲染
```

---

## 2. 技术栈与工程结构

| 层 | 选型 |
|---|---|
| UI | Flutter 3.47.9 / Dart 3.13、Riverpod 3、Material 3（seed 主题色）、`flutter_staggered_grid_view` 0.8.0-dev.3（推荐流双列/三列瀑布流；0.7.x 不支持 Dart 3） |
| 内核 | Rust（从同仓库族 `fqapp` 整体 fork）：签名 / 设备池 / 请求 / 限流 / 重试 / 正文解密 / CENC 解密 / 回环 HTTP |
| 桥接 | flutter_rust_bridge 2.13.0（进程内 FFI，不走 socket） |
| 播放 | `video_player` 2.14.1；`video_player_avfoundation` 用 `third_party/` 本地补丁（补 `AVPlayer.defaultRate`，修 iOS 倍速复位） |
| 存储 | `shared_preferences`（书架/进度/设置）、`flutter_secure_storage`（设备池密钥）、`path_provider`（沙盒目录）、`cached_network_image` + `flutter_cache_manager`（封面） |

```
lib/
  app/            MaterialApp、启动闸门、类型化路由、底部 tab 外壳、主题、共享组件
  core/           core/backend（FRB 传输与内核启动）、core/cache（封面/占用/清理）、core/storage（书架进度 + offline/）
  data/           api_client、models、parsers（card_walker / novel_parsers / video_parsers）
  features/       recommend / feed / detail / reader / video / mine / settings / cache
  src/rust/       FRB 生成绑定（勿手改）
rust/             Rust 内核（fork 基线与本地补丁见 PATCHES.md）
third_party/      打过补丁的 video_player_avfoundation
scripts/          build_rust_ios.sh / build_rust_android.sh（含 FRB codegen）
test/             解析/缓存/并发/存储测试 + test/ui/ 页面测试 + goldens/
integration_test/ 阅读分页真机性能 harness
```

启动链：

```
main.dart（锁竖屏、预读主题色/深浅色/推荐布局、裁剪封面缓存）
  → BootstrapGate（Splash，失败展示可读原因 + 重试）
  → BackendService.start()（把 assets/config 的 config.json / device_pool 部署到 <AppSupport>/backend/config）
  → BackendTransport.start()（Keychain 取设备池密钥 → rust.setDevicePoolKey → rust.init）
  → 内核 init 同时起回环 HTTP（默认 127.0.0.1:18931，端口唯一来源 assets/config/config.json）
```

iOS 上内核是**静态库链进主二进制**（`-force_load`），FRB 用 `ExternalLibrary.process()`；
Android 是 `.so`，FRB 走默认 `DynamicLibrary.open('libfqapi_core.so')`。

---

## 3. 请求链路（两条链路共用）

### 3.1 一次业务请求

```text
页面 / Riverpod controller
  → ApiClient.xxx()                                    拼 path + query，选超时
  → BackendTransport.send()                            lib/core/backend/backend_transport.dart
       · 内核 504 → BackendTimeoutException（真实超时）
       · 内核 499 → TimeoutException('backend cancelled')（主动取消，不算错误）
  → FRB rust.request(request_id, method, path, query, body, timeout_ms)
  → rust/src/dispatch.rs::dispatch                     FFI 与回环共用同一套业务实现
  → router 匹配 → endpoint handler → 上游 HTTPS
  → HTTP 形状响应（status + bytes）→ ApiClient._getJson 校验信封、归一 ApiException
  → 模型（lib/data/models/）
```

- 签名、设备池、限流、重试、正文解密全在 Rust；Dart 只传 `(request_id, method, path, query, body, timeout_ms)`。
- Rust 侧重试：同一设备对传输错误/429/5xx 退避重试，设备级失败会换设备；`Retry-After` 有上限，
  请求有总时间预算。Dart **不做通用自动重试循环**，只决定要不要给用户「重试」入口；唯一例外是
  推荐流首屏的有界重试（见「推荐」节：2 次退避 + 回前台补拉，只为覆盖首次安装的联网权限弹窗）。
- 错误模型：`ApiException { message, kind }`，`kind` ∈
  `bad_input / device_failed / rate_limited / upstream_5xx / timeout / too_large / unknown`；
  统一文案 `apiErrorCopy()`，只有技术兜底 message 才换成人话。

### 3.2 回环 HTTP

回环服务只给**媒体**和外部调试客户端用，Dart 业务请求不经过它：

- 免 capability：`/health`、`/src/*`，以及 App 自用的 7 个读接口；其余 fqapp/Legado 兼容路由对无 capability 调用返回 404。
- `/src/*` 支持 200 / 206 / 416：既服务明文静态文件（漫画图等），也服务 CENC 密文视频的按 Range 解密。
- 每次启动随机 32B token；Host/Origin 校验防 DNS rebinding 与跨站写。
- iOS 需 ATS 例外放行 127.0.0.1；Android 用 `network_security_config` 放行明文回环。
- **监听自愈（iOS，Apple TN2277）**：App 被挂起时系统可能回收 `listen()` socket 的底层资源，
  回到前台 listener 已不再监听且没有可靠通知（`accept` 返回 `EBADF`）；axum 的 accept 循环
  对错误无限重试、永不返回，所以监听任务既不会退出也不会重建。`server.rs` 改为监督任务：
  每 2s 用 TCP connect 自探活（间隔必须小：Apple `Instant` 基于 `mach_absolute_time`，
  熄屏睡眠期间不前进），探测被拒即 abort accept 循环、丢弃旧 socket、**同端口立即重绑**
  （失败才 250ms→5s 退避；绑定统一走 `TcpSocket + SO_REUSEADDR`，避免旧连接 TIME_WAIT
  造成 EADDRINUSE）。端口 / capability token / `baseUrl()` 全部不变，已发出的 `/src` URL
  继续有效；只在 accepting / reclaimed+rebinding / rebound / stopped 四个状态转换打日志。
- **App 侧兜底**：`BackendTransport.waitForLoopbackHealthy()` 用 `dart:io` 发真实 HTTP
  `GET /health` 探活（FFI 请求不经过回环 adapter，探不出来），`BackendService.ensureLoopback()`
  串行兜底整核 `shutdown` + `init`；播放页对 -1004 只做一次有界恢复重试（见 §5.7）。

### 3.3 上游接口与分类

书城首页是**同一个接口按 `tab_type` 分类**：

```
GET /api/v1/recommend/homepage?tab_type=<分类>&offset=<游标>&tab_index=0&session_id=<翻页必回传>
```

| tab_type | 内容 | 实测行为 |
|---|---|---|
| 2 | 小说推荐 | 约 22 张/页，可翻页 |
| 8 | **短剧** | 6 张/页，`next_offset` 逐页 +1 |
| 24 | 漫剧 | 12 张，但 offset>0 返回空（无游标） |
| 16 | 视频 feed | 只回 2 张、无游标（不用） |

搜索是另一条接口：`GET /api/v1/search?query=&tab_type=&offset=&count=`，
tab 语义：1 综合 / 2 听书 / 3 书籍 / 8 漫画 / **11 短剧**。

两条必须遵守的上游规则：

1. **响应按 `tab_type` 认领**：`data.tab_item` 是整条顶栏，只有被回答项带 `cell_data`，
   `data.tab_index` 指向它；`tab_type` 对不上就是别的分类，整页拒绝。
2. **翻页只认游标前进**：`has_more` 不可信，`next_offset > 当前 offset` 才算有下一页。

分类差异收在 `lib/features/recommend/content_source.dart` 的 `ContentSource`
（`NovelSource` / `DramaSource` / `ManjuSource`）；漫剧没有独立搜索 tab，用短剧搜索
（`tab_type=11`）后按 `genre=205` /「漫剧」标签过滤，首页无游标时用搜索兜底翻页。

其它业务路由：`/api/v1/books/{id}/detail`、`.../directory`、`/api/v1/chapters/{id}/novel`、
`/api/v1/chapters/{id}`、`/api/v1/chapters/batch`、`/api/v1/series/{id}`、`/api/v1/videos/{id}`。
Rust 内核注册了 50 个 fqapp/Legado 兼容路由，App 实际只用 7 个 endpoint（9 条 path）；
回环对无 capability 调用只放行 App 用的那 7 个读接口（FFI 不受白名单限制）。

---

## 4. 小说链路：JSON → 分页 → 文字

### 4.1 入口与详情

```text
推荐卡 / 搜索页卡 → DetailRoute
  → detailBundleProvider = Future.wait([bookDetail, directory])   lib/features/detail/detail_providers.dart
       失败 → 读 offline/novel/<bookKey>/book.json 兜底（书名/封面/目录）
  → 进度 → 主按钮「继续阅读 · 第N章」
  → 点主按钮 / 目录某章 → _openReader() → ReaderRoute(ReaderArgs{bookId, chapterId?, chapterIndex?, blockIndex?})
```

续读入口带 `blockIndex`（页首段落下标），显式点章不带（从页首开始）。
`chapter()` 首选 `/chapters/{id}/novel`，失败回退 `/chapters/{id}`；详情/目录不做持久缓存。
详情最下方用一张卡片展示书籍 ID（左侧 ID、右侧复制图标）并支持一键复制：数据就绪后才渲染、随内容一起淡入（避免先出现再被简介/目录顶下去）。

### 4.2 打开阅读页（bootstrap）

`readerSessionProvider` 在 `build()` 里 `unawaited(_bootstrap())`：

```text
await OfflineBookStore.read(bookId)                    ← 磁盘
   ├─ 有 book.json 且章节非空 → 本地目录（按数组顺序重排 index）
   │    → _resolveStart() → await _loadChapter(start)
   │    → unawaited(_refreshDirectoryInBackground())（成功按 chapterId 保留当前章替换；失败静默）
   └─ 没有 manifest → await api.directory(bookId) + 详情（仅补书名/封面）
        → _resolveStart() → await _loadChapter(start)
```

起始章优先级：显式 `chapterId` > 本地进度 `chapterId` > 进度 `chapterIndex` > 第 0 章。
只有「本地进度」这条路恢复 `blockIndex`（页内落点）。

### 4.3 章节正文：严格三层读取

```text
① offline pinned：OfflineBookStore.readChapter(bookId, chapterId)
     命中 → 直接展示（连 loading 都不置）→ 预取邻章 → return
② 自动缓存：ReaderChapterCache.get(chapterId)（内存 LRU 8 → 磁盘 300 文件）
     命中 → 直接展示；isStale（>7 天）→ 先展示，同时入队后台静默刷新
③ 网络：api.chapter(chapterId) → parseChapterContent → 展示
     unawaited(_cache.put) → 预取邻章
     失败 → 首次进入（还没有正文）整页「正文加载失败」+ 重试；
            已读到正文时保留正在显示的章，错误降级为正文顶部提示条
            （重试 / 关闭），index 退回 contentIndex、失败章记在 failedIndex
```

- 代际 `_requestToken` 保证快速切章时旧响应不覆盖新章；`_applyContent` 按 `chapterId`
  在当前目录里重找位置，后台换目录不会把正文挂错章。
- 离线命中**不回写**自动缓存；自动层只是加速器。
- ±1 章预取：队列上限 4、worker 并发 1、只写缓存不动 UI；失败静默。
- **三章阅读窗口**：当前章稳定后，阅读页把前后各一章的正文 + 章评 + 分页一起准备好
  （正文走 `prepareChapterContent`，章评顺带拉取并本地缓存，分页在 post-frame 预排），
  窗口外（例如 1→2→3 后的第 1 章）由 `_prunePrepared` 淘汰。PageView 在前后各放一个
  sentinel 页（上一章最后一页 / 下一章第一页），到边界继续滑/点左右分区和章内翻页走
  同一条 PageView 动画；落定后原子切章并抑制旧的淡入过渡。sentinel 未就绪时仍回退到
  原来的越界切章 + 淡入路径。
- **老正文补锚点**：缓存/离线正文没有 `paraIndices`（升级前写入的老文件）且气泡开启时，
  后台补取一次正文：只有真拿到 `<p idx>` 锚点才回填当前章。自动缓存来源同时写回缓存；
  离线来源只记在会话内（切走再回来仍生效），不覆盖离线 pinned 区、也不写自动缓存。
  补取回来仍无锚点（纯文本源）就不替换正文；自动缓存来源写回新版 schema（`v`）后不再
  重试，离线来源每章每次会话最多一次。断网静默、下次打开再试。

### 4.4 网络与解密

| ApiClient 方法 | Rust 处理器 | 上游 & 解密 |
|---|---|---|
| `bookDetail` | `book.rs` `book_detail_legacy` | `fanqienovel.com/reading/bookapi/detail/v`，不加密 |
| `directory` | `book.rs` `directory` | `api5-normal-*.fqnovel.com/.../directory/all_items/v`，不加密 |
| `chapter` 首选 | `dhcontent.rs` `fetch_novel_reader_content` | `novel.snssdk.com/.../reader/content/v1`，**DH 握手**解密，响应置 `content_decrypted=true` |
| `chapter` 回退 | `content.rs` `handle_single(api_type="full")` | `reading.snssdk.com/reading/reader/full/v`，**AES-128-CBC** + 设备 `secret_key` |
| `chaptersBatch` | `content.rs` `handle_batch` | `api5-normal-*.fqnovel.com/.../batch_full/v`，逐项 AES 解密；**只给离线整本下载用** |

`parseChapterContent` 有三条硬规则：显式 `content_decrypted != true` 抛「正文尚未解密」；
`htmlToParagraphs` 切段并丢掉图片/脚本、裁掉与标题重复的首段；空正文抛「正文为空」。

### 4.5 解析 → 分页 → 渲染

```text
ChapterContent{id,title,paragraphs}
  → ReaderSessionState（chapters/index 与 content/contentIndex 分离，loading/error）
  → _obtainPagination()：key = 正文对象身份 + 宽高 + 字号 + 行距 + 系统缩放 + 字体
  → ReaderPagination.build()：每段一个 TextSpan → TextPainter.layout → 按【行边界】装页
       （每页至少一行防死循环，段间距 = fontSize × 0.55）
       同时用同一次 layout 的 getBoxesForSelection 算对话高亮矩形 → ReaderBlock
  → PageView.builder → ReaderPageContent
       每个 fragment：Positioned(top,height) + ClipRect + OverflowBox(段高)
                     + Transform.translate(-sourceTop)
                     + Stack[对话色带 CustomPaint, Text.rich(整段)]
       只裁剪、不重排：上屏断行与测量永远同一套
```

- 分页进度存「本页真正开头的段落下标」，不是跨页段落号；恢复时找包含该段的第一页。
- 字号/行距/字重/系统缩放变化 → 进 key，重新分页并按旧页锚点回位；换底色只改颜色，不重排。
- 对话高亮：`“…”` / `「…」` / `『…』` 引号内的说话内容（不含引号）在测量阶段
  用 `getBoxesForSelection` 算出段内矩形，渲染时在文字下方画标记。三种画法由
  `DialogueHighlightStyle` 决定：**荧光笔**（矩形下半段圆角色带，透明度浅色纸
  34% / 夜间纸 22%）、**下划线**、**波浪线**（后两者都是贴着行盒 88% 处的线，
  透明度 85% / 90%，因为「线」比「面」需要更实的颜色；波浪线半波 3.2、峰谷
  ±2.4）。颜色与样式都在设置页「主题 → 对话高亮」的同一个弹层里选（默认琥珀黄
  + 荧光笔；样式点完立即生效，颜色等「确定」）；**换样式只重绘、不重新分页**
  （样式不进 `_PaginationKey`），矩形来自这次 TextPainter 测量，渲染期不额外排版，
  也不影响分页、选中和复制。
  真实源常把一句话拆成多个 `<p>`，扫描器
  （`ReaderDialogueScanner`）按整章顺序保留未闭合引号，跨段对话/每段重复左引号
  的排版都能连起来；状态不跨章。可在阅读设置里关闭（只影响渲染、不触发重排）。
- 空章显示「本章暂无正文」+ 上/下一章（空章没有可翻页的正文，保留这条兜底入口）。
- 工具栏：点中间 1/3 区域呼出；打开时横向翻页锁定（PageView `NeverScrollableScrollPhysics`），
  压暗遮罩保留但不接收点击（点击穿透到正文，用于收起工具栏）。
  顶部为返回 + 书名（与右侧状态动作同字号，占返回键与动作之间的剩余宽度，超宽省略，
  不会挤压右侧按钮）+ 右对齐的两个文本动作：书架状态（`加入书架` → `已在书架`，加入后
  只读、只加不移，状态读 `readerShelfProvider`）与整本缓存状态（`缓存小说` 可点开始下载，
  `缓存中` / `已缓存` 点击进缓存中心；状态与详情页 `OfflineDownloadButton` 共用
  `offlineEntryStatusProvider`）。详情页缓存按钮与缓存中心的「继续/重试」都走同一个 `startOfflineDownload`：入队回执、空间不足/队列满的文案、字节格式化（`core/cache/app_cache.dart` 的 `formatBytes`）只有一份。底部为目录/详情/评论/日间·夜间/设置，上一章/下一章不再占
  按钮位（点正文左右分区、章边界继续滑动、目录跳章都能切章）。日/夜切换：夜间用
  `ReaderPaper.night`，切回日间回到上次选择的浅色纸（落盘 `reader_day_paper_v1`）。

### 4.6 进度与设置

- 进度：`{chapterId, chapterIndex, blockIndex, updatedAt}`，`blockIndex` 是页首段落下标。
- 写入：翻页 5s 防抖（`ReaderController.progressDebounce`）、切章立即 flush、退出阅读页与
  App 切前后台（`inactive`/`paused`）再兜一次；同一本书的重复落点复用同一行 UPDATE。
- 表：与书架/收藏同表，`library` 里一行（`type='novel'` + `source_id`），进度落
  `progress_ref / progress_index / progress_sub`，看过的书就是「历史」的来源。
- 设置：字号 15–30（默认 **21**）、行距 1.3–2.0（默认 **1.8**）、字重 300–800（默认 **400**，整百档）、4 种底色（色块与「底色」标题同一行，不显示文字）、对话高亮开关
  （默认开）与颜色（默认 `#FFD54F`，设置页主题模块自定义）、段评气泡开关（默认开），落
  `reader_font_size_v1 / reader_line_height_v1 / reader_font_weight_v1 / reader_paper_v1 / reader_day_paper_v1 / reader_show_dialogue_highlight_v1 / reader_dialogue_highlight_color_v1 / reader_show_bubbles_v1`；
  `reader_day_paper_v1` 记住最近一次浅色纸，供工具栏日/夜切换切回；已落盘偏好优先，
  默认值只影响无历史偏好的用户。

### 4.7 评论 / 段评（只读）

内核 `comments.rs` 与 fqapp 同源，接口已齐，Dart 不需要 Rust 改动；FFI 调用不受
loopback `APP_APIS` 白名单限制。全部读接口都是匿名设备签名（DeviceSigned），**不需要登录**。

```text
打开章节
 ├─ 正文解析保留 <p idx="N"> → ChapterContent.paraIndices；目录读 item_data_list[].version → Chapter.version
 └─ GET /chapters/{id}/reviews（整章一次）
      → data.data = { "0": {count, infos[]}, "28": …, "10000": … }
      → total = 各段 count 之和；有 idx 且 count>0 的段画段尾气泡
      → 工具栏「评论」入口 = idea map 里段号最大的桶（约定 10000+）

点气泡 / 工具栏「评论」
 └─ 评论面板（0.76 屏高）
      ├─ GET /books/{bookId}/reviews?group_id={章节id}&group_type=15
      │     &comment_source=2&comment_type=1&server_channel=38
      │     &para_index=N&item_version={version}&count=20[&cursor=…]
      ├─ 滚动近底用 cursor 拉下一页（cursor 不前进就停止）
      └─ 「N 条回复」→ GET /comments/{commentId}/replies?book_id=&group_id=&count=10
```

约定：

- **只读**：没有发评论/点赞/回复入口（内核只有短剧写接口，小说段评写接口不存在）。
- **配图只读展示**：评论正文的 `content.image_data_list.image_data[].web_url` 由
  `parseCommentImageRefs` 归一成 http(s) 绝对 URL（兼容协议相对地址 / `&amp;` / 去重），
  评论与回复都渲染缩略图；点开全屏查看器可左右切图、双指缩放，单击画面任意处（或右上角 x）立即关闭。图片走
  `AppImageCache`（与封面共用磁盘缓存），只做展示，不参与任何写操作。
- **表情内联渲染**：正文里的 `[微笑]` 等 53 个官方 token 由 `CommentEmojiText`
  换成包内 120×120 webp（字号 1.4 倍、与文字垂直居中）；未知 token 保留原文，
  无 token 的评论仍走普通 `Text`。素材合计约 126 KB，离线可用，不发额外请求。
- **装饰失败静默**：`chapterIdeasProvider` 失败一律 `ChapterIdeas.empty`，阅读页不进入错误态。
- **锚点缺失不瞎猜**：没有 `paraIndices` 的段不画气泡；升级前写入的老缓存/老离线正文
  会在后台补取一次带锚点的正文（见 §4.3），纯文本回退源补取后仍无锚点、不替换正文。
  目录缺 `version` 时段评正文可能回 103001，面板给「加载失败 + 重试」，不影响正文。
- **气泡只跟最后一行同行**：测量时先看末行剩余空间，气泡放得下才画；放不下就不画
  （避免气泡独占一行、以及 widget 行高与占位高度不一致导致的裁切/盖字）。
- **气泡样式**：自绘**空心对话气泡**——透明底 + 主题色描边 + **左侧朝左**的小尾巴，数字居中，
  `>99` 显示 `99+`；三种 variant 只换描边/数字配色（普通 / 有读者 / 作者），不引图片素材。
  尾巴朝左指向它标注的段落：气泡挂在段末行尾，朝下会顶到下一段行首。
- **汇总重新请求不闪**：离线进入时目录后台刷新会把章的 `version` 从空换成网络值，
  idea list 会按新 `version` 重新请求；页面在结果回来前沿用当前章上一份汇总
  （`_resolveIdeas`），避免已经画出来的气泡先消失再出现。
- **离线**：断网时评论请求必失败、静默；离线正文缺锚点会在线时补取一次（见 §4.3），纯断网阅读仍无气泡。
- **缓存兼容**：`reader_chapters/` 与 `offline/novel/` 的章节 JSON 增加可选 `paraIndices`
  与 schema 版本 `v`；读取时长度必须与 paragraphs 对齐，否则当无锚点。老文件没有 `v`
  （按 0 算），命中后标记 `anchorsOutdated`，由阅读页补取一次带锚点的正文。

书评（详情页）走另一条旧接口 `GET /books/{id}/comments`（0–10 分 + `comment_cnt` /
`2.6万人点评` 文案），卡片只露第一条，弹窗按 `offset` 翻页。

**短剧评论**（与段评/书评共用同一套 `BookComment` 模型，内核路由早已存在，Dart 走 FFI）：

```text
进入短剧详情
 └─ GET /api/v1/series/{sid}/comments?count=20
      → 剧评卡片（只露第一条）+「查看全部 N 条」；同一页数据直接交给弹层（cursor 翻页）

播放页点「本集评论」
 └─ GET /api/v1/series/{sid}/hot-comments?vid={当前集id}
      → 本集评论（官方热评，comment_source=4 / group_type=30 / server_channel=18，
        20 条/页，common_list_info.cursor 翻页；business_param.book_id=剧集 id）
```

- 短剧评论没有评分字段，卡片/弹层都不画星级；vid 为空时 Dart 侧直接短路，避免上游静默退化成剧级评论。
- **本集评论 channel 必须 18**：17 会返回 `code=0`、`common_list_info.total>0`、`data_list=[]`
  的「成功」空响应（实测同一剧集 17 空列表、18 返回 20 条）。弹层首屏遇到「total>0 但列表空」
  会自动重试一次，仍空则显示可重试错误，不再显示「共 N 条 + 还没有评论」。
- **评论列表统一**：阅读页段评/章评、详情页书评、短剧剧评、本集评论都由同一个
  `CommentListSheet` + `CommentFeed` 驱动。共享层只维护列表/分页/错误/空态/footer/
  评论行排版；书评 `_BookReviewsFeed` 持有 legacy offset，短剧 `_VideoCommentsFeed` 持有
  `common_list_info.cursor`，阅读页 `_ReaderParagraphFeed` 持有段评 cursor + 回复懒加载，
  阅读页通过 `CommentSheetStyle` 跟随纸色主题，其余评论跟随 App 明暗主题。短剧翻页页的
  total 常为 0，共享层保留首屏 total。评论行不再画列表分割线，空态/加载/失败样式四套一致。
- 剧评失败静默（provider 返回 null，详情页整块不渲染）；评论弹层首屏失败才显示「重试」。
- 弹幕（`/videos/{vid}/danmaku`）本期不接；写评论/点赞/回复也不接。

**请求频率**（全部由用户动作触发，无轮询 / 无后台预取 / 无逐段请求）：

| 动作 | 请求 |
|---|---|
| 打开一章（段评气泡开） | 1 次 idea list（整章计数，切章才发） |
| 老缓存/老离线正文缺锚点（气泡开） | 该章首次 +1 次正文；自动缓存来源写回新 schema 后不再发；离线来源每章每次会话各一次 |
| 段评气泡关 | **0 次**；点工具栏「评论」时才发 1 次 idea list |
| 打开评论面板 | 1 次评论列表（20 条/页），滚动翻页每页 1 次，「N 条回复」每次展开 1 次 |
| 进入小说详情页 | 1 次书评（20 条），弹窗滚动翻页每页 1 次 |
| 进入短剧详情页 | 1 次剧评（20 条），弹窗滚动翻页每页 1 次 |
| 打开播放页「本集评论」 | 1 次 hot-comments（20 条/页）；滚动近底每页 1 次 |

---

## 5. 短剧链路：密文 → 回环解密 → 播放器

### 5.1 入口与选集

```text
推荐卡 → VideoDetailRoute
  → videoDetailBundleProvider = Future.wait([videoDetail, videoEpisodes])
       失败 → 读 offline/video/<seriesKey>/series.json 兜底（剧名/封面/选集）
  → 选集（详情页 36 集/组、播放页 78 集/tab 弹层、我的最近观看先拉目录）
  → VideoPlayRoute{seriesId, seriesTitle, cover, episodes, index}
  → 播放页 initState → _open(index)
```

整份 `episodes` 带进播放页，换集不再回源目录。
详情最下方用卡片展示短剧 ID（左侧 ID、右侧复制图标）并支持一键复制（数据就绪后才随内容淡入）；选集也收在同一套卡风格里；播放页「选集」弹层
按 78 集/tab 分组（区间标签，打开定位当前集所在 tab，每 tab 内 6 列网格可滚动）。

### 5.2 `_open`：四段来源，顺序固定

```text
_open(index, {retainPrevious})
  ├─ sync：_generation++、取消定时器；同页重载 → _retainCurrentController()（旧帧垫底）；
  │        翻页兜底加载 → 直接释放旧 controller（旧页已滑出）
  ├─ sync：loading=true；有旧帧 → spinner 延迟 250ms，无旧帧 → 立即显示
  │
  ├─ ① 离线 pinned：_offlineFile(episodeId)
  │     命中 → VideoPlayerController.file → initialize → play（不联网、不碰内核）
  ├─ ② 页内预取 LRU（当前集播 5s 后预取下一集，最多 2 条）
  │     命中 → 直接拿现成 /src 地址初始化
  ├─ ③ mode=cached 探测（内核只 stat 本地文件，不联网）
  │     命中 → /src 直接初始化
  └─ ④ 正常取流：api.videoSource(episodeId, refresh, variants=0)
        上游 1 个 RTT + 整集下载 → /src/<id>.<ext>
  ▼
_startController：initialize → setPlaybackSpeed → setLooping(false)
  → 上屏（loading=false）→ play() → 控制条 3.5s 自动隐藏 → 5s 后预取下一集 → 记进度
  ▼
_onTick：同页重载时新集 position>0 才释放旧帧；播到尾部自动 _changeEpisode(+1) 整页续播
```

每一步都有 `mounted + generation` 校验，切集/退出时旧结果直接丢弃。

### 5.3 正常取流：内核做什么

| 步骤 | 说明 |
|---|---|
| 参数 | `mode=stream/cached`、`refresh=1`、`variants=0`、`max_height`（下载清晰度上限）、`prefer_height`（在线播放档位偏好，播放页传 720） |
| `mode=cached` | 只查 `src/<id>{.mp4,.m4s,.ts}`（>0 字节、密文必须有可读 `.key`），**完全不打上游** |
| `mode=stream`（M1） | 复用上面的取流/选档结果，启动后台下载到 `src/<id>.mp4.part`，拿到上游响应头（Content-Length）后**立即**返回本地 `/src` 地址（`streaming:true`），不读 body、不等整集落盘；同 id 复用进行中的会话，已有完整缓存直接按 cached 返回；`.m4s/.ts`、拿不到 Content-Length、启动失败 → 退回整集下载（`streaming:false`） |
| 取上游 | 主取流打 V5 播放门 `multi_video_model/player/v1`（见下）；V5 请求失败 / 解析不出模型 / 选流 `NotFound` 时回落 legacy：播放默认只打 phoenix `multi_video_model`，stream / 带 `max_height` 时并发 shortplay+phoenix 合并档位 |
| 选档 | 分数 `宽×1e9 + 高×1e6 + 码率 (+h264/avc1 1)`；`bytevc2` 整档排除；无 `prefer_height` 时按分数从高到低。在线播放传 `prefer_height=720`：短边 720 的档排最前（同档再按分数），**没有 720P 时退回最高可解码档**；按该顺序取第一个能解出 url+key 的档（720 档解不出会自动落到下一档，不会选流失败） |
| 清晰度上限 | `max_height` → 短边 ≤N 的最高档；没有更低档 → 最低可用档 + `quality_fallback=true` |
| 整集下载 | 流式写 `.part` → rename `src/<id>.<ext>`（**CENC 密文原样落盘**），密文再写 `.key` sidecar、有档位写 `.variant.json` |
| 淘汰 | `src/` 总预算 **128 MiB**（与漫画图共享），每次下载后异步按 mtime 最旧删，跳过 `.part/.tmp` |

下载限制：总超时 15s、单文件 2 GiB 上限、只接受 200；失败删 `.part`。

**V5 播放门（2026-11）**：上游 2026-11 中旬把短剧取流换成 `multi_video_model/player/v1`，
旧的 argus 签名请求被统一拒绝，表现为整片短剧无法起播。该门的签名由 `rust/src/sign/v5.rs`
负责（`x-medusa` + SM3，`aid=8662`、`version_code=74332`），协议要点：

- 请求体先 gzip，再对**线上字节**做 MD5 进 `x-ss-stub`、做 SM3 进签名——压缩必须排在签名之前，签完不得再改 body；
- query/header 全部由签名器生成，**不走**通用 `Manager::generate_headers`，因此请求不带 `x-argus`；
- 429/5xx/传输错误在同设备上退避重试，只有 HTTP 401/403 才判定设备失效并换号。
`mode=stream` 的后台下载沿用同一超时；失败时删除 `.part` 与预写的 `.key`，等待中的 Range 请求收到 502。
若只拿到远程加密地址（未落盘），Dart 直接报「整集缓存失败」。

### 5.4 回环 `/src`：Range + CENC 解密

```text
AVPlayer/ExoPlayer
  → GET http://127.0.0.1:18931/src/<id>.mp4（Range）
  → Host/Origin 校验 → dispatch → /src 免 capability
  → serve_src_file：只处理 .mp4 且密文；缺 .key → 503；Range → 200/206/416
  → cenc_index_for_file（按 path+len+mtime 内存缓存；moov 读取上限 16 MiB）
  → 64 KiB 流式分块：encv/enca → avc1/hvc1 头补丁 + 每 sample AES-CTR 解密
  → 明文 mp4 字节流 → 播放器解码
```

**磁盘上永远是密文，明文只存在于响应流里。**

下载中的流式服务（M1）：

```text
AVPlayer
  → GET /src/<id>.mp4（Range）
  → confined_candidate 命中进行中的 stream 会话
  → 等上游 Content-Length（最长 30s；失败/超时 → 502 JSON）
  → 请求区间超出已下载字节 → watch 等待（最长 30s）
  → .part 的 moov（faststart：ftyp + moov 在前 ~200 KiB）→ 按上游 total 建 CencIndex
  → 硬链接快照 .stream-snap-<pid>-<n>.snap（60s 后删）→ 按 Range 解密
  → 200/206/416；HEAD 只回头（不解密、不等数据）
下载完成：.part rename 成 src/<id>.mp4 + .key + .variant.json → 后续走上面的完成文件路径
```

- 会话 registry 按最终路径复用/替换（`refresh=1` 取消在跑会话）；孤儿会话 2min 回收，陈旧快照 10min 清理；与整集下载共用 per-entry 锁，不会互相截断 `.part`。
- 失败形态：Range 等待超时/下载失败 → 502 `{"success":false,"error":"streaming video unavailable: ..."}`；密文缺 key → 503；`mode=stream` 整集回退失败 → 500（客户端据此回退默认 `mode`）。
- `.m4s/.ts` 不支持流式 → `mode=stream` 退回整集下载后返回（`streaming:false`）；不带 Range 的整文件 GET 会等整集完成（iOS AVPlayer 走 Range；Android 需真机验证）。

### 5.5 渲染与交互

- 渲染通路：固定 `VideoViewType.platformView`（iOS = AVPlayerLayer，Android = ExoPlayer 平台视图），避免逐帧纹理拷贝。
- 切集：整页竖向 `PageView`（上滑下一集 / 下滑上一集），控制条里不再有上一集/下一集按钮；
  选集弹层跨集跳转直接 jump 到目标页，播完自动续播走相邻页 280ms 动画。
  - 拖动一开始（第一个 `ScrollUpdate` 判断出方向）就**预热**目标集，不等滑过一半：解析来源
    （离线 / 预取 / `mode=cached` / `mode=stream`）+ `initialize` + 暂停在第 0 帧，不碰当前播放。
    未就绪时相邻页先显示**剧封面**（暗化；无封面退回黑底），预热完成即 `setState` 切成首帧，
    所以滑动过程中能同时看到当前集画面和下一集封面/首帧。
  - 落定提交时每页恒定套同一层 `GestureDetector`（只有当前页的 `onTap` 生效），widget 树类型
    不随 `_index` 变化，`VideoPlayer` 的 State/platform view 原地保留，避免 iOS 闪一下黑。
  - `ScrollEndNotification` 落定后提交：预热命中就直接接管（首帧立即可见，不闪「正在准备
    视频」），并释放旧 controller；滑回落定则丢弃预热、恢复原集播放（**不重播**）。
  - 预热失败或未预热（程序化跳页等）才走 `_open` 兜底（错误展示与 -1004 恢复都在这）。
    预热页滑入时已能显示新集第一帧，未就绪则显示轻量占位（小 spinner + 集名），不是大
    「正在准备视频」页。
  - 错误页额外给上一集/下一集出口（错误页内部滚动区可能吃掉上下滑手势）。
- 起播：在线 MP4 优先 `mode=stream` 边下边播（内核立即返回 `/src`，Range 等字节），不再等整集落盘；
  流式取流/初始化失败回退一次默认整集下载，播放不倒退；-1004 一次性探活自愈不变。
- 预取：当前集播 5s 后预取下一集；优先 `mode=stream`（立即拿地址 + 触发下一集后台下载，失败回退整集下载）；离线命中跳过；页内 LRU 2 条；失败静默。
- 缓存与卸载（切集相关）：峰值最多 2 个 AVPlayer（当前 + 预热中的目标集，暂停在第 0 帧），
  提交/取消时立刻释放不要的那个；未预热的页面不建 controller；页内只预取下一集取流地址
  （LRU 2 条 `/src`，不预建 controller）；磁盘侧由内核 `src/` 128 MiB 预算按 mtime 自动淘汰，
  离线 pinned 区不受影响；离开播放页 dispose 所有 controller 与定时器。
- 倍速：1.0–3.0x 全局持久化（`video_playback_speed_v1`）；`_startController` 统一 apply，首帧/seek/恢复再补设一次；
  iOS 根因修复在 `third_party/video_player_avfoundation`（补 `AVPlayer.defaultRate`）。chip 放在
  操作行最右（右下角）；时间行只留「当前位置 — 总时长」。点 chip 弹出**贴着它展开的小浮窗**
  （`PlaybackSpeedButton`，M3 `MenuAnchor`；平时向下展开，控制条贴底放不下时自动翻到 chip 上方），
  只列 `playbackSpeeds` 那一份档位、不写说明文案；菜单开/关通过 `onOpenChanged` 冻结自动隐藏，
  避免选到一半控制条淡出。
- 全屏：只有横屏视频（aspectRatio > 1.05）才给入口，且**不在控制条里**——入口是视频画面下方 8px 的
  「全屏观看」提示（图标 + 文案，半透明胶囊，随控制条淡出；全屏时与竖屏视频不显示）。进入放开横屏 +
  隐藏状态栏；退出/返回/离开/切到竖屏视频都恢复竖屏（全屏时顶栏返回键先退全屏）。
  全屏横屏下同样支持上下滑切集；旋转（进出全屏）后按新 viewport 高度把 PageView 拉回当前集，
  避免 pixel offset 不换算导致停在半页。
- 进度：**只记到集**，`play()` 成功后才写 `video_progress_v1` + `video_history_v1`（最近 3 条）。

### 5.6 离线整剧下载（第二条独立链路）

```text
详情底栏「缓存」→ OfflineDownloader.startVideoSeries()
  · 单任务 + FIFO 队列（内存 ≤20，kind+id 去重）；paused 时队列停住
  · 3 GiB 软上限：开始只挡「已满」，下载中逐集检查
  · 先写 series.json 全量剧集/元信息，进度 30s 防抖
  ▼ 逐集（跳过已缓存）
api.videoSource(episodeId, maxHeight=默认720P)
  → HttpClient GET <回环>/src/...（Accept-Encoding: identity，只接受 200）
  → 流式写 <episodeKey>.mp4.part → commitEpisode（rename）
  → 单集失败重试 1 次；连续 3 集失败暂停并提示
```

落盘的是**回环解密后的明文 mp4**，播放时 `VideoPlayerController.file` 直接读本地文件。
`series.json` 记录每集体积、是否已缓存、实际档位，以及剧级 `qualityMaxHeight`，
供离线详情兜底、按缺口续传、缓存中心展示。

### 5.7 错误分类

取流超时 / 取流失败 / ATS 拦截 / 回环连接中断 / -1004「本地视频服务未响应」/ 解码失败 / 本地地址失效 / 未离线缓存。
技术详情可复制，「重新下载这一集」= `refresh=1`。

-1004（`NSURLErrorCannotConnectToHost`，「Could not connect to the server.」）就是回环监听被系统回收
（§3.2）：单独归类，并且先做**一次**有界恢复——`ensureLoopback()` 探活/必要时整核重启，成功后重开这一集；
恢复仍失败才显示错误页（不是通用自动重试循环）。

断网时：`mode=cached` 命中可播（FRB 不走 socket，`/src` 是本机文件）。
cached miss 时第一次取流仍会按内核重试预算耗一段时间，失败后进入**会话级「疑似离线」**
（`NetworkHealth`，TTL 90s）：后续切集不再重复等取流，直接提示「该集未离线缓存」；
任一次取流成功或用户点「重试」都会清掉标记并强制走一次完整网络请求。
预取在疑似离线期间也会跳过。

---

## 6. 缓存与本地存储

三层，物理隔离、语义不同：

| 层 | 目录 | 内容 | 淘汰 |
|---|---|---|---|
| **pinned 离线区** | `<AppSupport>/offline/novel/`、`offline/video/` | 用户主动下载的正文 / 明文 mp4 | **永不自动淘汰**，只能用户删 |
| **自动加速层** | `<AppSupport>/reader_chapters/`、`backend/src/` | 章节 JSON、CENC 密文视频 + `.key` | 各自有上限，自动淘汰 |
| **用户库** | `<AppSupport>/library.db`（SQLite） | 书架、收藏、阅读/观看进度 | 每条内容一行；纯进度行上限 500（小说+短剧共享），淘汰写 `progress_pruned_at` 不删行 |
| **偏好** | `SharedPreferences` | 主题、阅读设置、同步元数据 | 表级 LRU |

### 6.1 清单

| 位置 | 格式 / key | 上限 / TTL |
|---|---|---|
| `offline/novel/<b64url(bookId)>/book.json` | `OfflineBook`（章节列表 + 元信息） | 无 TTL；小说区 1 GiB 软上限 |
| `offline/novel/<bookKey>/<b64url(chapterId)>.json` | `{v,id,title,paragraphs[,paraIndices],fetchedAt}` 明文 | 无 TTL |
| `offline/video/<b64url(seriesId)>/series.json` | 剧集列表 + 档位 + 进度 | 无 TTL；短剧区 3 GiB 软上限 |
| `offline/video/<seriesKey>/<b64url(episodeId)>.mp4` | **明文 mp4** | 无 TTL |
| `reader_chapters/<b64url(chapterId)>.json` | `{v,id,title,paragraphs[,paraIndices],fetchedAt}` | 300 文件（mtime）、7 天 stale、内存 LRU 8 |
| `backend/src/<videoId>.mp4` | **CENC 密文** | 总预算 128 MiB，最旧优先 |
| `backend/src/<videoId>.<ext>.key` | hex 密钥 sidecar | 随视频删 |
| `backend/src/<videoId>.<ext>.variant.json` | `{name,width,height,short_edge}` | 随视频删 |
| `Application Support/libCachedImageData.db` + `Library/Caches/libCachedImageData/` | 封面图 + sqflite 索引 | 120 对象 / 7 天；启动 >40 MB 裁到 25 MB |
| `backend/config/` | 设备池 + 运行时 config | **不是缓存**，删了要重新注册设备 |
| `library.db` | 书架/收藏/进度（单表 `library`，`type` 区分小说/短剧） | **不是缓存**，删了等于清空书架 |
| `backend/rust.log`、`offline/diag.log` | 排障日志 | 轮转；可随时删 |

> **升级不迁移（1.0.1 → 本版本）**：`shared_preferences` 里的 `shelf_books_v1` /
> `reading_progress_v1` / `video_*` 不会被导入 `library.db`。覆盖升级后书架与历史
> 从空开始，旧 key 仍留在原处；要保留数据需手工转成 `library` 行或重新同步。
> 云同步同样**只认 `schemaVersion = 3`**：旧的 `sync.json` 会报「云端同步文件格式
> 不正确，已停止覆盖」，不会用空数据覆盖远端。

### 6.2 隔离不变式

1. 离线区不参与任何自动淘汰 / TTL / 体积裁剪；`AppCache.clear()` 只清自动层，**永不碰 `offline/`**（有回归用例）。
2. 小说 / 短剧两个离线区相互独立：目录、manifest、统计、清空互不影响。
3. 软上限：小说 1 GiB、短剧 3 GiB，超限阻止新任务并引导去「我的 → 缓存」清理。
4. 下载任务同一时刻只有一个；切后台在当前章/集结束后暂停，回前台不自动继续；删除前先取消任务/排队项。
5. manifest schema 读不懂时当「没有缓存」，不删文件。

清理入口：「设置 → 存储」只清自动缓存；离线 pinned 区统一在「我的 → 页头右上角『缓存』」打开的缓存中心里删除/清空（推荐页顶栏已无缓存入口）。

---

## 7. 构建、测试与质量门禁

### 7.1 环境

Flutter 3.47.9、Rust 1.99.1、Xcode 27.x、CocoaPods 1.17、JDK 17、Android SDK 36 / NDK 28.2.13676358。
FRB codegen 与 `rust/Cargo.toml` 必须同为 2.13.0。

### 7.2 iOS

```bash
flutter pub get
./scripts/build_rust_ios.sh              # 编真机 arm64 静态库 → ios/Frameworks/libfqapi_core.a
./scripts/build_rust_ios.sh --simulator  # 需要模拟器时额外编两片并打 xcframework
pod install                              # 新增/更新插件后
flutter build ios --release --no-codesign
# 产物 build/ios/iphoneos/Runner.app，打成未签名 IPA 后走 ios-sideload 自签安装
```

Bundle ID `com.lihangyu.novelPlaylet`，显示名「摆烂盒子」。`Info.plist` 已为 `127.0.0.1`
开 ATS 例外（视频回环）。真机排障取日志：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.lihangyu.novelPlaylet \
  --source 'Library/Application Support/backend' --destination /tmp/np-backend
# rust.log（内核日志）、config/device_pool.json（密文）
```

#### release / beta 双版本（同时安装，数据独立）

同一台 iPhone 上装两个 App：正式版从 `main` 构建，β 版从开发分支构建。两者
App ID 不同，iOS 会分配独立的沙盒容器与 keychain，互不影响；日常开发只覆盖
β 版，正式版的书籍 / 离线 / 阅读进度不会被卸载或签名事故带走。

| 版本 | Bundle ID | 显示名 | 回环端口 |
|---|---|---|---|
| release | `com.lihangyu.novelPlaylet` | 摆烂盒子 | `config.json`（18931） |
| beta | `com.lihangyu.novelPlaylet.beta` | 摆烂盒子 Beta | `BACKEND_PORT`（18932） |

- **端口必须错开**：`127.0.0.1` 是设备级共享的，两个 App 同时运行时，后启动的
  那个监听同一端口会 bind 失败、启动闸门卡住。β 版由
  `--dart-define=BACKEND_PORT=18932` 覆盖（`BackendService` 显式传给内核），
  release 仍读 `assets/config/config.json`。
- **构建**（两个 flavor 共用 Rust 静态库，`--skip-rust` 可跳过内核重编）：

```bash
./scripts/build_ios_app.sh --flavor release   # 建议在 main 上跑
./scripts/build_ios_app.sh --flavor beta      # 开发分支的包
# 产物 build/ios/ipa/novel_playlet_<flavor>_<sha>_unsigned.ipa
```

  脚本会改未签名包的 `CFBundleIdentifier` / `CFBundleDisplayName`（beta 加 Beta
  后缀），签名仍由 ios-sideload 按目标 App ID 完成。
- **签名**：两个 App ID 各有自己的描述文件。切换版本签名前先确认
  `~/workspace/ios-sideload/build/signer.mobileprovision` 的 App ID 与之匹配，
  不匹配就 `BUNDLE_ID=<app id> ./profile.sh --mint` 重新签发（免费账号 7 天一轮，
  两个版本各续一次）。建议把两份 profile 备份成
  `signer.release.mobileprovision` / `signer.beta.mobileprovision`，用哪个就拷回
  `signer.mobileprovision`。
- **安装**：`./install.sh -f <signed.ipa> -d <iPhone 名称/UDID>`。同一个 App ID
  覆盖安装是升级（保留数据），**不要卸载**。
- 抓日志 / 拷数据时用对应 bundle id（beta 是 `com.lihangyu.novelPlaylet.beta`）。

### 7.3 Android

```bash
./scripts/build_rust_android.sh                         # 内核 .so → jniLibs/arm64-v8a
./scripts/build_rust_android.sh --abis all              # 需要 32 位时
flutter build apk --release --target-platform android-arm64
# 产物 build/app/outputs/flutter-apk/app-release.apk
```

- Manifest 已补 `INTERNET`、`network_security_config`（只放行 127.0.0.1 明文回环）、备份排除规则、图标与显示名。
- 正式签名读 `android/key.properties`（仓库外，git 忽略）；没有配置时回退 debug 签名，只能自测、不能覆盖升级。
- 常见问题：启动报 `UnsatisfiedLinkError` → `.so` 没编或 ABI 不对；release 包接口全失败 → 缺 `INTERNET`；
  播放报 `PanicException(... rustls-platform-verifier ...)` → 旧包，重新构建；装不上 → 签名不一致，先卸载。

### 7.4 测试与门禁

```bash
make check             # = CI 三个 job：Dart format/analyze/test、Rust fmt/clippy/test、FRB 绑定漂移
make format            # 就地格式化
flutter test           # 数据解析 + 缓存 + 并发 + 存储 + UI golden，不需要网络/内核/模拟器
flutter test --update-goldens   # 更新 test/goldens/*.png
LIVE_PROBE=1 flutter test test/live_probe_test.dart   # 真实上游探针（需 host dylib + 网络）
```

- `test/ui/` 按页面拆分（recommend / home / detail / video / reader / mine / settings / cache-center），
  共享 `test/ui/preview_harness.dart`；golden 依赖 macOS 系统字体。
- CI 在 `.github/workflows/ci.yml`（当前只保留 `workflow_dispatch` 手动触发）：Flutter 门禁跑 macOS
  （golden 需要系统字体），Rust 门禁跑 Linux，外加 FRB 漂移校验与 iOS 无签名构建。
- `integration_test/reader_pagination_perf_test.dart` 是真机 performance harness，不进 CI（见 §8）。
- 书旗（`shuqi_contract` / `shuqi_live`）与漫画（`manga_end_to_end`）的契约测试默认
  `#[ignore]`：App 的 `APP_APIS` 不暴露这两条链路，保留它们只作 fqapp 上游同步的护栏。
  需要时手动跑：`cargo test --manifest-path rust/Cargo.toml --test shuqi_contract -- --ignored`
  （漫画同理）。

### 7.5 真机覆盖安装与缓存保留（iOS 自签）

- **覆盖安装不丢数据的前提**：同一个 bundle id + 同一个 Team（`529D3FU98W`）用
  `xcrun devicectl device install app` 安装；这是升级（update），不会卸载 App，数据容器
  （离线书/短剧、阅读章节缓存、偏好、播放进度）原样保留。ios-sideload 的 `install.sh` 走的就是
  `devicectl install`，**不要用会先卸载的工具/流程**。
- 装前保险（可选但推荐，约 1 分钟 / 300MB 以内）：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.lihangyu.novelPlaylet \
  --source 'Library/Application Support' --destination ~/np-backup-<时间>
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.lihangyu.novelPlaylet \
  --source 'Library/Preferences' --destination ~/np-backup-<时间>/Preferences
```

- 装后校验（缓存是否保留）：对比 `offline/` 下 mp4 和章节 JSON 的 sha、`reader_chapters/` 文件数、
  `backend/src/` 内核缓存；`book.json` / `series.json` 的 `updatedAt` 可能因启动对账被重写（内容/数量不变，
  属正常）。`backend/config/device_pool.json` 被内核改名成 `.corrupt-*` 是设备池密钥读不到时的自愈，
  只影响匿名设备重新注册，不影响缓存内容。
- **签名 7 天到期**后 App 会闪退，重跑一次 sideload 的 `all.sh` 续签即可；覆盖安装同样不丢数据。
- 装完可直接启动验证：`xcrun devicectl device process launch --device <UDID> com.lihangyu.novelPlaylet`。

---

### 7.6 版本号与发版

`pubspec.yaml` 的 `version: X.Y.Z+N` 是唯一来源（iOS 的 `CFBundleShortVersionString` / `CFBundleVersion`、Android 的 `versionName` / `versionCode` 都由它派生）。

- **release 只从 main 构建**；每次发版版本名 patch +1、构建号 +1：`1.0.0+15` → `1.0.1+16` → `1.0.2+17` …
- **beta / 开发包不改版本**，沿用当前 pubspec（两个版本靠 bundle id 与显示名区分，见 §7.2）。beta 构建脚本额外带 `--dart-define=APP_FLAVOR=beta`，设置页版本脚注据此显示 `Beta`（release 显示 `Release`），不用看 bundle id。
- 递增用脚本（默认 patch 与构建号各 +1；需要时再手动 `--minor` / `--major`）：

```bash
./scripts/bump_version.sh --dry-run   # 先看结果
./scripts/bump_version.sh             # 1.0.0+15 → 1.0.1+16
```

- 发版顺序：在 main 上 bump → 构建 release（`flutter build ios --release --no-codesign`，双版本构建脚本见 §7.2）→ 自签覆盖安装。不要手改 Info.plist / Android 的版本号。
- 构建号必须递增（Apple 的 `CFBundleVersion` 规则，覆盖安装和安全回滚都靠它），不要回退。

## 8. 性能记录：阅读页整章分页

结论：**保持整章同步分页，不做分帧补页**。

- 设备 iPhone 13（iOS 27.2），`flutter drive --profile`，样本 150 段/章 × 12 章。
- 冷启动打开阅读页：17 帧，UI build p50 0.11ms / p95 54.33ms / max 61.72ms，2 帧超 16.7ms（含首帧建树/光栅化）。
- 连续切 10 次章：每次恰好 1 帧超预算（17.6–28.8ms，中位数约 19ms），raster max 2.21ms。
- 按线性折算约 0.12–0.19ms/段，常见 60–80 段的章节约 8–15ms，在 16.7ms 预算内；
  只有 150 段以上超长章才稳定掉 1 帧，而且切章时保留上一章正文 + 顶部加载 pill，观感代价很小。
- 分帧补页会让页数从「部分」变「最终」（页码跳变、章末判断延后），收益不划算。
  若以后要优化首开手感，优先试「空闲帧预分页下一章」，而不是分帧补页。

复现：

```bash
flutter drive --profile -d <iPhone UDID> \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/reader_pagination_perf_test.dart
# 结果落 build/reader_pagination_perf.json；--dart-define=PERF_PARAGRAPHS=<n> 改段落数
```

---

## 9. 已知限制与不做的事

**明确不做**：画中画 / HDR / 后台播放 / AirPlay / 锁屏媒体信息、弹幕、听书、漫画、登录、
在线清晰度切换（C1）、秒级播放进度、iOS 后台下载；评论/段评只做**只读**（不发评论、不点赞、不回复）。

**当前限制**：

1. 首次打开必须联网完成设备注册（`log.snssdk.com`），失败停在「阅读环境启动失败」。
2. 短剧在线起播已接入流式回环（M1）：MP4 边下边播，不再等整集落盘；`mode=cached` 命中依旧秒开。
   仍有限制：`.m4s/.ts`、拿不到 Content-Length 的上游退回整集下载；Range 未下载数据最多等 30s，
   超时/下载失败会 502 并让客户端回退整集下载；不带 Range 的整文件请求等价整集等待（Android ExoPlayer 需真机验证）。
   断网后第一次取流仍可能耗到内核重试预算（黑洞网络约几十秒），之后进入「疑似离线」
   快速失败（见 §5.7），用户手动重试会再试一次完整网络。
3. 清晰度：在线播放默认 720P（传 `prefer_height=720`，没有 720P 时退回当次最高可解码档；不可手动切换）；下载清晰度另走 `max_height`，可设**离线整剧下载**的最高/1080P/720P/480P（默认 720P）。
4. 倍速 3x 在在线源上可能被 AVFoundation 静默 clamp 成 2x（已接受，不 fork 插件）。
5. 离线下载：仅前台；按章/集粒度续传，无字节级断点；同时一个任务，队列只在内存里；不支持选集下载。
6. 离线内容明文落盘（小说正文与短剧 mp4），未做加密。
7. 离线 manifest 只存封面 URL，未落盘封面文件；离线管理列表可能显示占位块。
8. 视频进度只记到「集」，重进从 0 秒开始；退后台不主动暂停。
9. 漫剧详情走短剧详情路由，真实上游尚未完整验证；漫剧搜索兜底流的元数据可能不完整。
10. Android 播放运行时（全屏/后台/倍速/断网 cached）仍待真机全面验证。
11. `chaptersBatch` 解密失败时内核保留密文且不置 `content_decrypted`，离线整本下载的「回退单章」未完整闭环。
12. App 全局锁竖屏；只有播放页横屏视频可进全屏。
13. iOS 上架需处理 GPLv3 与内容授权，当前定位自用/自签。
14. 评论/段评/书评**只读**：不能发评论、点赞、回复；离线阅读不显示段评/书评；纯文本回退源或
    老缓存没有段落锚点时只显示章末聚合评论、不画气泡。

**可优化点**（现状观察，非承诺）：阅读页 bootstrap 重复请求目录；详情 `Future.wait` 任一失败丢弃部分成功结果；
首次网络类失败仍无法提前判定（没有 connectivity 能力），只能等内核重试预算；`serve_src_file` 只处理 `.mp4`（`.m4s/.ts` 会退回明文静态服务）。

---

## 10. 相关文件索引

| 文件 | 内容 |
|---|---|
| `CONTRACTS.md` | 页面开发约定：数据层 API、存储 API、路由、状态管理、测试门禁 |
| `PATCHES.md` | Rust 内核相对 fqapp 的 fork 基线、本地补丁清单与上游同步流程 |
| `third_party/README.md` | `video_player_avfoundation` 补丁内容与插件升级时如何重放 |
| `lib/features/recommend/content_source.dart` | 分类策略（tab_type / 搜索 tab / 漫剧兜底） |
| `lib/features/recommend/recommend_layout.dart` | 推荐流布局（双列 / 三列）provider 与持久化 |
| `lib/features/recommend/recommend_skeleton.dart` | 推荐流首屏骨架（与真卡同列宽 / 封面比例 / 行高，静态色块） |
| `lib/features/feed/feed_staggered_grid.dart` | 推荐流瀑布流（sliver 网格 + 列宽换算，卡片不定高） |
| `lib/app/widgets/surface_card.dart` | 通用白底卡容器（推荐流先接入，后续列表逐步复用） |
| `lib/features/cache/offline_downloader.dart` | 离线下载引擎（单任务状态机 + 队列） |
| `lib/data/models/{chapter_ideas,book_comment,comment_reply}.dart` | 段评/书评/回复模型与解析 |
| `lib/data/models/comment_image.dart` | 评论配图 URL 解析与归一（协议相对地址 / `&amp;` / 去重） |
| `lib/app/widgets/comment_image_{loader,strip,viewer}.dart` | 评论配图加载（AppImageCache）/ 缩略图 / 全屏查看器 |
| `lib/app/widgets/comment_emoji_text.dart` | 评论/回复方括号表情：token 解析、包内 webp 内联渲染 |
| `assets/images/emoji/` | 官方 53 个表情 token 对应的 120×120 webp（约 126 KB） |
| `lib/features/settings/widgets/dialogue_highlight_preview.dart` | 对话高亮取色弹层里的阅读页示例预览 |
| `lib/features/sync/{webdav_config,webdav_client,sync_service,sync_status}.dart` | WebDAV 云同步：配置安全存储、HTTP 客户端（ETag/If-Match）、合并上传、状态机 |
| `lib/features/sync/{sync_log,sync_log_page}.dart` | 同步日志：本机 50 次记录（双向 diff）、记录页 |
| `lib/features/sync/widgets/webdav_{sync_card,config_sheet}.dart` | 设置页云同步卡片与配置/测试连接表单 |
| `lib/core/storage/reading_store.dart` | 书架/收藏 tombstone、同步导出与按条 LWW 合并 |

| `lib/features/reader/{reader_comments,reader_comments_sheet,reader_bubble}.dart` | 段评 provider / 评论面板（共用列表壳 + 回复 Feed）/ 段尾气泡 |
| `lib/app/widgets/comment_list_sheet.dart` | 全部评论列表共用壳：`CommentListSheet` / `CommentFeed` / 评论行 / 回复区 / 纸色 Style |
| `lib/features/detail/{detail_reviews_section,detail_reviews_sheet}.dart` | 详情页书评卡片与弹窗（书评 offset Feed） |
| `lib/features/video/network_health.dart` | 会话级「疑似离线」标记：断网后切集快速失败、手动重试强制联网 |
| `lib/features/video/{video_comments_providers,video_comments_sheet}.dart` | 短剧剧评 provider / 剧评与本集评论弹层（cursor Feed） |
| `lib/app/widgets/app_snack_bar.dart` | 全站统一轻提示（1s，替换 SnackBar 默认 4s） |
| `lib/app/widgets/app_bottom_sheet.dart` | 全站底部弹层骨架：统一圆角/遮罩/底部安全区 + 标题区（主副标题行内排布）+ 右上角关闭 + 内容插槽 |
| `rust/src/endpoints/video.rs` | 取流、选档、整集下载、缓存淘汰、`/src` 解密 |
| `rust/src/endpoints/{book,content,dhcontent}.rs` | 详情、目录、正文（DH / AES）与批量正文 |
| `.github/workflows/ci.yml` / `Makefile` | 质量门禁 |

---

## 11. 附录：推荐列表字段与卡片元信息（2026-11-08 抓包）

> 数据来源：macOS host 加载内核 dylib 直连上游，抓 `/api/v1/recommend/homepage` 的
> `tab_type=2`（小说 27 本）、`tab_type=8`（短剧 6 部）、`tab_type=24`（漫剧 12 部）各一页原样响应。
> 内核对该接口**原样透传上游 JSON**，字段解析全部在 Dart 侧。

### 11.1 卡片元信息展示规则（已实现）

| 链路 | 双列（默认，`reasonOnCover: true`） | 三列（`reasonOnCover: false`） |
|---|---|---|
| 小说（`NovelGridCard`） | 文字区：作者（作者空退回分类）左 / `rank_score`（热度，如「8479万热度」）右，同一行；`recommend_reason_list` 第一条的 `content`（如「巅峰榜No.3」「19个老书虫在看」「细糠」）做成封面左上角角标 | 文字区逐行、有就显示：作者、推荐理由、热度 |
| 短剧/漫剧（`VideoCard`） | 文字区：「全 N 集」左 / `rec_text`（热度，如「4691万热度」；`show_rec_text=false` 时不展示）右，同一行；推荐理由（JSON 串里 `rec_tags[0].content` → `tag_info.text` → `sub_title_list` / `secondary_info_list`）做成封面左上角角标 | 文字区逐行、有就显示：集数、推荐理由、热度 |

- 代码：固定信息 = 作者 / 集数；可选字段逐条非空即显示。双列走 `MediaCard.coverBadge`
  （理由上封面，最大宽度 = 卡宽 − 72，给右上评分角标让位，长理由省略号）+ `metaTrailing`
  （热度右对齐到作者/集数行尾）；三列走 `MediaCard.extraMeta`（每条一行、空串不占位）。
  `NovelGridCard` / `VideoCard` 在 `showRecommendMeta` 时传入，`reasonOnCover` 由
  `RecommendPage` 按 `layout.columns == 2` 决定（搜索页固定 `reasonOnCover: false`，理由/热度有就各占一行）。
  统一提取 `lib/data/models/json_utils.dart::firstReasonText()`；模型字段
  `NovelItem.{recommendReason,rankScore,score}`、`VideoSeries.{score,recommendReason,rankScore}`
  （`lib/data/parsers/video_parsers.dart`）；搜索页开 `showRecommendMeta`（作者/集数 + 评分角标；
  视频卡再关掉推荐理由，只留集数 + 热度）；书架/收藏同样不开推荐元信息，但已卡片化：
  小说只展示书名 + 作者（作者缺失不回退分类，`NovelGridCard.fallbackToCategory=false`），
  短剧只展示剧名 + 全 N 集。
- 两种 `recommend_reason_list` 形态必须分别处理：**小说是数组**（元素对象取 `content`），
  **短剧/漫剧是 JSON 字符串**（解析后取 `rec_tags` / `tag_info` / `sub_title_list`）。
- 评分：`score` 是字符串；`0` / `0.0` / 空都算未评分，展示时统一补「分」。
  推荐卡评分固定在封面右上角角标（`MediaCard.cornerText`，白字 + 半透明深色底 + 轻阴影），
  不再混进作者/集数行；短剧详情页也在标题下用「星标 + 8.2分」展示。
- 详情页标题下信息行：评分 + 「N 人在读」同一行；「更新至 第 x 章 …」单独起一行，
  用满卡片内容宽度（不再和评分/在读分宽度），只有超出卡片宽度才省略号。这两行
  与上面的「作者 · 状态 · 字数」同为 `bodyMedium`（不用更小的 `bodySmall`），
  星标随字号略放大到 17。

### 11.2 小说列表 `book_data` 关键字段（27 本样本）

| 字段 | 样例 | 现状 / 可用位置 |
|---|---|---|
| `book_id` / `book_name` / `author` / `thumb_url` | — | 列表卡片已渲染 |
| `score` | `9.0`（样本 27/27，6.9–9.5） | 推荐卡封面右上角角标 + 详情页星标 |
| `rank_score` | `8479万热度`（16/27） | 元信息附加行（有就显示） |
| `recommend_reason_list` | `[{content:"巅峰榜No.3", can_click:true, ...}]`（7/27） | 元信息附加行（有就显示） |
| `category` / `tags` | `传统玄幻` / `传统玄幻,玄幻` | 卡片分类兜底、详情标签 |
| `word_number` | `2286030` | 详情已渲染字数；列表可做第二行/角标 |
| `creation_status` | `1`（0 连载 / 1 完结） | 详情已渲染；列表可做角标 |
| `serial_count` | `1052` | 总章数，候选 |
| `last_chapter_title` | `第1052章 …` | 详情「更新至」已渲染；列表候选 |
| `read_cnt_text` / `read_count` | `225.5万人在读` / `2254443` | 详情已用；列表候选（占宽度） |
| `read_count_all` | `14099373` | 累计阅读，候选 |
| `all_bookshelf_count` | `309` | 「X 人加书架」，候选 |
| `listen_count` | `1260` | 听书人数，候选 |
| `exclusive` / `top_right_icon` / `sub_title` | `1` / `null` / `""` | 运营角标候选 |
| `color_dominate` | `#201818`（27/27） | **已用**：封面还没加载出来 / 缺失时的占位底色（`NovelCover.placeholderColor`，避免一片灰块） |
| `back_color_dominate` | `#131F37`（22/27） | `color_dominate` 缺失时兜底的占位色 |
| `recommend_info` / `quality_rate` / `data_rate` | 内部埋点 / 质量权重 | 不渲染 |

### 11.3 短剧/漫剧列表 `video_data` 关键字段（18 部样本）

| 字段 | 样例 | 现状 / 可用位置 |
|---|---|---|
| `series_id` / `title` / `cover` / `episode_cnt` | — | 列表卡片已渲染 |
| `score` | `8.2`（tab 8/24 全有，8.0–8.3） | 推荐卡封面右上角角标（与小说一致）+ 短剧详情页星标 |
| `recommend_reason_list` | JSON 串：`{tag_info:{text:"上新"}, rec_tags:[{content:"系列剧·40万人在追"}], sub_title_list:[{content:"剧情"}]}` | 元信息附加行（有就显示） |
| `rec_text` / `show_rec_text` | `4691万热度` / `true` | 元信息附加行（热度，有就显示） |
| `color_dominate` / `back_color_dominate` | 抓包样本未出现 | 兼容解析：有就用于封面占位色（`NovelCover.placeholderColor`），没有就退回系统灰 |
| `play_cnt` | `5862787` | 播放量，候选（可格式化成「586万」） |
| `rec_tags` | `["系列剧·40万人在追","27万人收藏","小说改编","年代"]` | 多标签角标候选 |
| `tag_info` | `{text:"上新"/"热门"/"爆款", bg_color, dark_bg_color, icon_url}` | 角标 + 配色/图标候选 |
| `sub_title` / `sub_title_list` | `剧情·149集` / `["剧情","149集"]` | 分类·集数，候选副标题 |
| `category_schema` | `[{name:"年代"},…]` | 分类（可点） |
| `video_desc` | 长文本 | 简介（列表未渲染） |
| `duration` / `episode` / `vertical` / `video_platform` | `12551` / `true` / `true` / `3` | 元数据 |
| `book_exist` / `support_listen` | `true` / `true` | 「有原著 / 可听书」候选 |
| `recommend_info` / `series_pred_score` | 内部埋点 | 不渲染 |

### 11.4 坑 / 设计约束

- 搜索页是横滑卡片行（复用同款白底卡、标题固定两行），不等于卡片网格；书架/收藏与推荐流
  同样是白底不定高卡片，标题按 1~2 行自然高度、没有元信息时不占行，高低差交给瀑布流吸收（见 11.5）。
  旧的紧凑网格（固定两行标题、固定行高）已随书架/收藏卡片化退场，不要再往新页面套。
  紧凑卡片的元信息只有**一行**且封面宽 108pt：继续叠加播放量/字数/状态等字段，建议放第二行或做封面角标，
  否则长作者名 + 长标签会挤成省略号（golden 里 `爱潜水的乌贼 · 9.…`）。
- 短剧 `recommend_reason_list.sub_title_list` 多为「剧情 / 149集」这类与卡片既有信息重复的分类，
  所以提取顺序是 `rec_tags` → `tag_info.text` → `sub_title_list`，不要反过来。
- 小说 `recommend_reason_list` 的 `content` 可能是「细糠」「19个老书虫在看」这类口语化文案，
  直接展示即可，不要二次加工。
- 短剧列表的 `tab_type=16`（单集视频）和 tab 8/24 结构不同（信息在 `video_detail` 里），App 不用 tab 16。

### 11.5 推荐流布局与封面比例（2026-11-09）

- **布局**：`SliverMasonryGrid`（`flutter_staggered_grid_view`，CONTRACTS 依赖白名单）按子节点实际
  高度排版，双列/三列共用一套卡片；列数来自 `recommendLayoutProvider`（设置页「主题 → 推荐流布局」，
  默认双列，持久化 key `home_recommend_layout_v1`，`main.dart` 启动预读避免首页先按双列渲染再跳）。
  旧的固定高度三列网格 `FeedGrid` / `FeedGridMetrics` 已删除，新增 `FeedStaggeredGrid`：
  卡片高度不再预算，列宽由 `SliverLayoutBuilder` 从 sliver 实际拿到的 `crossAxisExtent`
  算（不用 MediaQuery 屏宽，外层加留白/被放进窄容器时也不会错位）。
- **卡片**：`AppSurfaceCard`（浅色纯白底、暗色 `surfaceContainerHigh`、圆角
  `AppTheme.mediaCardRadius` = 10、无阴影）+ 封面满宽出血；封面 `NovelCover.radius` 传 0，
  顶部圆角由卡片裁、底部保持直角。通用白底卡抽在 `lib/app/widgets/surface_card.dart`，推荐流与「我的」页书架/收藏共用；
  书架/收藏的元信息收敛为：小说「书名 + 作者」、短剧「剧名 + 全 N 集」，不展示推荐理由/热度/评分。
  书架/收藏数据量级小，用 `MasonryGridView`（shrinkWrap、禁用自身滚动）嵌在「我的」页的
  `CustomScrollView` 里；列数/列宽仍由 `MineGridMetrics` 统一换算（手机 3 列）。
- **不定高来源**：标题自然 1~2 行 + 元信息为空时不占行（短剧缺集数）。小说标题较短，双列下大多一行
  放下；短剧/漫剧标题更长，错落更明显。想要更夸张的高低差得给卡片加内容（简介/字数），不在本期。
- **封面比例**：接口不返回封面尺寸，按内容域已知原生尺寸出图（`kNovelCoverAspect` = 320/240 = 4/3 ≈ 1.333，`kVideoCoverAspect` = 571/400
  ≈ 1.4275，都是高/宽；11:8 = 1.375 正好是两者中间）；书架 / 最近阅读 / 详情仍统一
  `kCoverAspect`（11:8）；搜索页按所属分类的原生比例。逐图真实比例需要解码后回填尺寸，会让瀑布流二次重排，暂不做。
- **不变的部分**：下拉刷新、滚动到底加载、首屏补页、底部 footer 全部复用
  `FeedView`，与列数无关；切换布局保持当前滚动位置（有意为之：`FeedView` 的 State 与 ScrollController
  不重建，深滚时换列数会停在新布局的相近位置，但不跳回顶部）。
- **golden**：新增 `feed_staggered_grid.png`（瀑布流本身）、`recommend_three_columns.png`、`recommend_dark.png`；
  推荐流/搜索页/设置页改版后需 `--update-goldens` 重生成 `recommend*.png`、`home*.png`、`search*.png`、`settings*.png`。


### 11.6 WebDAV 云同步（2026-11-16 第二版）

- **入口**：设置 → 同步。配置表单填 WebDAV 根地址、账号、应用密码；密码只进
  `flutter_secure_storage`（iOS Keychain / Android Keystore），不写 SharedPreferences、
  日志或同步 JSON。表单先「测试连接」（MKCOL + PUT/GET/DELETE 探针），成功后才允许保存。
  设置页一级有三个入口：**WebDAV**（弹层）、**同步记录**（本机最近 50 次）、
  **云端数据**（只读展示云端 `sync.json` 的元信息与 500 条上限内的记录列表）。
- **文件**：`novel-playlet/<release|beta|dev>/sync.json`。渠道由 `appFlavor` 与构建模式决定：
  release 包用 `release`，beta 包用 `beta`，debug 包用 `dev`，互不覆盖。文件只有书架、收藏、
  阅读/观看进度，封面只存 URL，不存正文/图片/密码，通常小于 100 KB。
- **合并**：单表 `library` 的记录直接进载荷（`{'items': [...]}`，`schemaVersion = 3`）：
  - 快照整组按 `metaFetchedAt` 取新；进度整组按 `lastReadAt` 取新；
  - 书架/收藏用 `shelfAt` / `shelfRemovedAt` 两列各取 max，`shelfAt > shelfRemovedAt` 才算在架，
    删除也能同步；
  - 进度淘汰墓碑：`progressPrunedAt` 晚于对方 `lastReadAt` 才丢弃，之后又读过会复活。
- **条件请求**：先 `PROPFIND Depth:0` 取 ETag，与本机 `SyncMeta.remoteEtag` + 本地载荷指纹
  （FNV-1a）比对，都命中就整轮跳过（不发 GET/PUT）。PROPFIND 不可用时用上次的 ETag 发条件
  GET（`If-None-Match`），命中 304 也直接跳过；两者都不可用（实测坚果云就是这种）就回退到
  无条件 GET + 内容比对，只保证不会白写 PUT，省不掉下载。
- **并发保护**：`PUT` 带 `If-Match: <etag>`；被另一台设备抢先写入（412/409）时重读 → 重合并
  → 重写，最多重试一次。写完再取一次 ETag 存回 `SyncMeta`。
- **同步时机**：App 回前台/退后台自动同步一次；设置页「立即同步」和保存配置会**并行**
  跑书架 + 设置两个文件；设置改动另有 1.6s 去抖与离开设置页 flush。
  阅读进度本身 5s 防抖落盘（切后台会在 `inactive` 先落盘，早于这里的 `paused` 同步）。
- **同步日志**：`<AppSupport>/sync-log.json` 保留最近 50 次，记录触发方式、结果、失败阶段、
  revision 变化、双向字段 diff（每向最多 20 条明细）。`scope` 区分书架（`library`）与设置
  （`settings`）；设置无变化不记，避免刷屏。它是本机诊断数据，不进 `library.db`、
  不进同步载荷；写入 best-effort，日志失败不影响同步。
- **错误**：云端 JSON 损坏或渠道不匹配时停止同步并报错，绝不用空数据覆盖；401/403、409、
  507 分别提示账号、上级目录、网盘配额问题。
- **测试**：`webdav_client_test.dart` 用本地 `HttpServer` 覆盖认证/探针/读写；`reading_store_sync_test.dart`
  覆盖合并/墓碑/裁剪墓碑；`webdav_sync_service_test.dart` 覆盖上传、拉取、条件跳过、412 重试、
  日志采集；`sync_log_test.dart` 覆盖双向 diff 与日志存储。

### 11.7 运行日志（诊断，2026-11-18）

- **入口**：设置 → 诊断 →「运行日志」。页面按天分组倒序展示，可展开看 HTTP 状态 / kind /
  耗时 / 异常堆栈，单条可复制；右上角可清空（只删本机日志）。
- **数据**：`<AppSupport>/app-log.json`，最多 300 条；同一级别 + 来源 + 摘要 8 秒内重复出现
  只增加计数（`×N`），避免断网时同一接口刷屏。日志是本机诊断数据，**不进 `library.db`、
  不进同步载荷**，写入 best-effort，失败只在控制台留一句。
- **来源**：
  - `api`：`ApiClient._getJson` 统一记录传输异常、HTTP 非 200、200 但 body 非 JSON / 非对象；
    另在「推荐返回的分类不匹配」「video_url 为空」「只拿到远程加密流」「批量正文缺失」
    「图文正文回退纯文本」等已兜底/不符合预期的地方记 `unexpected`。只记 method + path，
    **不记 query**（搜索词等用户数据不进日志）。
  - `app`：`installDiagnosticErrorHandlers()` 接管 `FlutterError.onError` 与
    `PlatformDispatcher.onError`，记录后仍交给原处理器（框架错误继续 `presentError`，
    异步错误返回 false），不改变崩溃/打印行为；`silent` 的框架错误不落日志。
- **不做**：远程上报、日志上传、全量请求审计；业务信封（HTTP 200 + 非 0 code）里的
  「没有段评」等软失败不记（会被当成噪音），请求成功也不记。
- **测试**：`diagnostic_log_test.dart` 覆盖排序/上限/合并/坏文件；`api_diagnostic_log_test.dart`
  覆盖 HTTP 失败、内核超时、非 JSON/非对象响应、URL 查询串脱敏；`diagnostic_error_handlers_test.dart`
  覆盖 silent 过滤与异步错误透传；
  `test/ui/app_log_page_test.dart` 覆盖列表/展开/空态与设置页入口。

### 11.8 设置项云同步（settings.json，2026-11-18）

- **入口/触发**：不新增手动按钮。冷启动 / `resumed` 拉取，设置改动 1.6s 去抖后推送，
  `paused` 与离开设置页 flush；「立即同步」同时跑书架与设置，保存 WebDAV 配置后也两者一起跑。
- **文件**：`novel-playlet/<release|beta|dev>/settings.json`，与 `sync.json` 完全独立；
  外层 `{v: 1, deviceId, updatedAt, settings}`。`v` 只认 1，更高版本直接停止同步、不降级覆盖。
- **内容**：主题（seed / mode / customSeed）、全局字重、推荐布局、阅读排版 10 项；
  **不同步**播放倍速与下载清晰度（设备相关）。枚举存 name（`system` / `two` / `parchment`），
  不存下标；脏值按字号 15–30、行距 1.3–2.0、字重整百档、纸色/样式白名单 clamp 或回落默认。
- **LWW**：本地 `settings_local_updated_at_v1` 记录最后一次变更时间；与云端 `updatedAt`
  比较，本地更新推本地，否则远端赢（时间相同远端赢）。apply 时用 `_applyingRemote` 屏蔽
  脏标记，绝不 ping-pong；推送带 `If-Match`，412 重读后按同一规则重判，最多重试一次。
- **防脏写**：apply 被沉浸页挡住时只更新 etag / remoteHash，不推进 `lastRemoteUpdatedAt`，
  离开沉浸页或下次 resumed 自动重试；不写 `updatedAt` 相同但 hash 不同的“假最新”。
- **挡板**：`ImmersivePageTracker` 在阅读页 / 播放页 / 设置页压栈时计数，`idle == 0` 才 apply；
  详情 / 搜索 / 缓存中心允许回填。
- **注册表**：`SettingsSection` 把主题、全局字重、推荐布局、阅读排版拆成 4 组；每组只实现
  `capture()` / `applyRemote()`，新增设置优先加字段而不是加一套同步代码。同步服务与 coordinator
  都不认识具体 provider，方便单测。
- **同步记录**：成功推送/拉取写一条 `scope = settings` 的记录；失败写失败阶段；无变化与
  沉浸页 deferred 不写。列表行用「设置」标记区分书架记录。
- **测试**：`settings_sync_test.dart` 覆盖推送/拉取/LWW/412/未知 v/沉浸页/脏值 clamp/coordinator；
  `sync_log_test.dart` 与 `test/ui/sync_log_test.dart` 覆盖 scope 字段与设置行展示。

### 11.9 首页空闲预热（热搜 / 榜单，2026-11-18）

- **触发**：推荐页小说流首个 `AsyncData` 后 400ms 的 `Timer`；只排一次，页面 dispose 时取消，
  不阻塞首屏。预热只做数据缓存，**不保活 SearchPage / RankPage 页面树**。
- **搜索热搜**：`hotSearchProvider` 改成进程级 `Notifier` + 10 分钟 TTL；首页预热一份，
  搜索页打开时 `ensureFresh()` 命中缓存直接展示，过期后台刷新，失败保留旧值/空榜。
- **推荐分类首屏**：后台 `ref.read(recommendFeedProvider(短剧/漫剧).future)` 把两个分类的
  第一页先拉好。推荐页默认在小说 tab，用户第一次切短剧/漫剧时直接命中 `AsyncData`，不再
  闪「正在加载短剧/漫剧」。失败则保持未加载，切过去按原逻辑重试。
- **排行榜**：`RankBoardCache` 缓存小说 / 短剧 / 漫剧三个内容域各自第一顺位榜的首屏（5 分钟 TTL）。`RankPage` 的每个
  榜单 tab 初始化时先读缓存：命中新鲜缓存不发首屏请求；过期时先画缓存再静默刷新，失败保留
  缓存。翻页数据不进缓存，仍由页面 `FeedState` 管。缓存写入会通知已打开的
  `_RankTabPage`：预热晚于页面首屏请求时直接替换 loading，随后网络结果再替换缓存。
- **预取服务**：`lib/features/prefetch/app_prefetch.dart` 并行预热「热搜 +
  三个内容域各自第一顺位榜的首屏」，不把小说的完本/巅峰/新书也拉一遍；失败静默。
- **目录复用**：`ApiClient.recommend` 把首页 payload 交给回调，`RecommendFeedController`
  顺手解析 `RankCatalog` 写进 `RankCatalogCache`，`rankCatalogProvider` 优先读它；预取和首次
  打开排行榜页都不再重复请求首页（实测这次重复请求约 4s）。
- **成本**：热搜 1 次 + 排行榜三个内容域首屏 3 次 + 短剧推荐首屏 1 次 + 漫剧推荐首屏
  1–2 次（漫剧首屏有搜索兜底），共约 6–7 次小请求；目录复用首页 payload 后不再额外请求。
  缓存只存列表对象和 URL，量级远小于保活页面。
- **排行榜转场**：`RankRoute` 用 `MaterialPageRoute`，跟着系统转场走（iOS 右进左出，带左边缘侧滑返回）。不要再换成 `PageRouteBuilder` 自定义「左侧滑入」：自定义转场会绕过 `PageTransitionsTheme`，iOS 侧滑返回手势随之失效，只能点返回按钮退出。
- **测试**：`prefetch_test.dart` 覆盖预热一次 / 重复调用不重复请求 / force 刷新 / 目录缓存
  命中不请求首页 / 短剧漫剧推荐首屏已就绪；
  `test/ui/rank_page_test.dart` 覆盖缓存命中不发首屏请求；`test/ui/home_test.dart` 覆盖
  首屏完成后触发预热。
