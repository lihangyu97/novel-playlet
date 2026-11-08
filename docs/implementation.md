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

- **推荐**：顶部搜索框 + 分类 tabs（小说 / 短剧 / 漫剧），每个分类独立推荐流与搜索结果，翻页、下拉刷新、首屏不足自动补页。
- **详情**：小说与短剧共用一套「封面头 + 简介卡 + 标签」版式；小说有目录，短剧有选集（36 集/组）。
- **阅读页**：`TextPainter` 真实分页、左右翻页、点击分区、工具栏、字号/行距/4 种底色、目录跳章、邻章预取、进度保存。
- **播放页**：`video_player`（iOS AVPlayer / Android ExoPlayer）、1.0–3.0x 倍速、控制条自动隐藏、上下集/播完自动下一集、选集弹层、横屏全屏、失败分类与「重新下载这一集」。
- **我的**：小说 / 短剧两块镜像面板（书架 / 收藏 + 最近阅读 / 最近观看 + 缓存与设置入口）。
- **缓存中心**：离线整本 / 整剧下载的进度、网速、排队、暂停/继续/删除/清空。
- **设置**：主题色、存储占用与清理、离线下载清晰度。

两个内容链路：

```text
小说：详情 → 目录 → 章节正文（缓存/网络）→ 解析 → TextPainter 分页 → 渲染
短剧：详情 → 选集 → 取流/缓存 → 回环解密 → AVPlayer/ExoPlayer 渲染
```

---

## 2. 技术栈与工程结构

| 层 | 选型 |
|---|---|
| UI | Flutter 3.47.9 / Dart 3.13、Riverpod 3、Material 3（seed 主题色） |
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
main.dart（锁竖屏、预读主题色、裁剪封面缓存）
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
  请求有总时间预算。Dart **不做自动重试循环**，只决定要不要给用户「重试」入口。
- 错误模型：`ApiException { message, kind }`，`kind` ∈
  `bad_input / device_failed / rate_limited / upstream_5xx / timeout / too_large / unknown`；
  统一文案 `apiErrorCopy()`，只有技术兜底 message 才换成人话。

### 3.2 回环 HTTP

回环服务只给**媒体**和外部调试客户端用，Dart 业务请求不经过它：

- 免 capability：`/health`、`/src/*`，以及 App 自用的 7 个读接口；其余 fqapp/Legado 兼容路由对无 capability 调用返回 404。
- `/src/*` 支持 200 / 206 / 416：既服务明文静态文件（漫画图等），也服务 CENC 密文视频的按 Range 解密。
- 每次启动随机 32B token；Host/Origin 校验防 DNS rebinding 与跨站写。
- iOS 需 ATS 例外放行 127.0.0.1；Android 用 `network_security_config` 放行明文回环。

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
推荐/搜索结果卡 → DetailRoute
  → detailBundleProvider = Future.wait([bookDetail, directory])   lib/features/detail/detail_providers.dart
       失败 → 读 offline/novel/<bookKey>/book.json 兜底（书名/封面/目录）
  → 进度 → 主按钮「继续阅读 · 第N章」
  → 点主按钮 / 目录某章 → _openReader() → ReaderRoute(ReaderArgs{bookId, chapterId?, chapterIndex?, blockIndex?})
```

续读入口带 `blockIndex`（页首段落下标），显式点章不带（从页首开始）。
`chapter()` 首选 `/chapters/{id}/novel`，失败回退 `/chapters/{id}`；详情/目录不做持久缓存。

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
  → PageView.builder → ReaderPageContent
       每个 fragment：Positioned(top,height) + ClipRect + OverflowBox(段高)
                     + Transform.translate(-sourceTop) + Text.rich(整段)
       只裁剪、不重排：上屏断行与测量永远同一套
```

- 分页进度存「本页真正开头的段落下标」，不是跨页段落号；恢复时找包含该段的第一页。
- 字号/行距/系统缩放变化 → 进 key，重新分页并按旧页锚点回位；换底色只改颜色，不重排。
- 空章显示「本章暂无正文」+ 上/下一章。

### 4.6 进度与设置

- 进度：`{chapterId, chapterIndex, blockIndex, updatedAt}`，`blockIndex` 是页首段落下标。
- 写入：翻页 400ms 防抖、切章立即 flush、页面 dispose 再兜一次。
- 表：`reading_progress_v1`（最近 200 本 LRU）+ `recent_reading_v1`（3 条）+ `last_read_book_v1`。
- 设置：字号 15–30、行距 1.3–2.0、4 种底色，落 `reader_font_size_v1 / reader_line_height_v1 / reader_paper_v1`。

---

## 5. 短剧链路：密文 → 回环解密 → 播放器

### 5.1 入口与选集

```text
推荐卡 → VideoDetailRoute
  → videoDetailBundleProvider = Future.wait([videoDetail, videoEpisodes])
       失败 → 读 offline/video/<seriesKey>/series.json 兜底（剧名/封面/选集）
  → 选集（详情页 36 集/组、播放页 6 列弹层、我的最近观看先拉目录）
  → VideoPlayRoute{seriesId, seriesTitle, cover, episodes, index}
  → 播放页 initState → _open(index)
```

整份 `episodes` 带进播放页，换集不再回源目录。

### 5.2 `_open`：四段来源，顺序固定

```text
_open(index)
  ├─ sync：_generation++、取消定时器、_retainCurrentController()（旧帧留下垫底）
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
_onTick：新集 position>0 才释放旧帧；播到尾部自动 _open(+1, autoAdvance)
```

每一步都有 `mounted + generation` 校验，切集/退出时旧结果直接丢弃。

### 5.3 正常取流：内核做什么

| 步骤 | 说明 |
|---|---|
| 参数 | `mode=stream/cached`、`refresh=1`、`variants=0`、`max_height` |
| `mode=cached` | 只查 `src/<id>{.mp4,.m4s,.ts}`（>0 字节、密文必须有可读 `.key`），**完全不打上游** |
| 取上游 | 播放默认只打 phoenix `multi_video_model`；stream / 带 `max_height` 时并发 shortplay+phoenix 合并档位 |
| 选档 | 分数 `宽×1e9 + 高×1e6 + 码率 (+h264/avc1 1)`；`bytevc2` 整档排除；从高到低取第一个能解出 url+key 的档 |
| 清晰度上限 | `max_height` → 短边 ≤N 的最高档；没有更低档 → 最低可用档 + `quality_fallback=true` |
| 整集下载 | 流式写 `.part` → rename `src/<id>.<ext>`（**CENC 密文原样落盘**），密文再写 `.key` sidecar、有档位写 `.variant.json` |
| 淘汰 | `src/` 总预算 **128 MiB**（与漫画图共享），每次下载后异步按 mtime 最旧删，跳过 `.part/.tmp` |

下载限制：总超时 15s、单文件 2 GiB 上限、只接受 200；失败删 `.part`。
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

### 5.5 渲染与交互

- 渲染通路：固定 `VideoViewType.platformView`（iOS = AVPlayerLayer，Android = ExoPlayer 平台视图），避免逐帧纹理拷贝。
- 切集：保留上一帧 + spinner 延迟 250ms；新集 `position>0` 后才释放旧帧。
- 预取：当前集播 5s 后预取下一集；离线命中跳过；先探 `mode=cached` 再 `videoSource`；页内 LRU 2 条；失败静默。
- 倍速：1.0–3.0x 全局持久化（`video_playback_speed_v1`）；`_startController` 统一 apply，首帧/seek/恢复再补设一次；
  iOS 根因修复在 `third_party/video_player_avfoundation`（补 `AVPlayer.defaultRate`）。
- 全屏：只有横屏视频（aspectRatio > 1.05）给按钮；进入放开横屏 + 隐藏状态栏；退出/返回/离开/切到竖屏视频都恢复竖屏。
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

取流超时 / 取流失败 / ATS 拦截 / 回环连接中断 / 解码失败 / 本地地址失效 / 未离线缓存。
技术详情可复制，「重新下载这一集」= `refresh=1`。

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
| **偏好/进度** | `SharedPreferences` | 书架、进度、设置、主题 | 表级 LRU |

### 6.1 清单

| 位置 | 格式 / key | 上限 / TTL |
|---|---|---|
| `offline/novel/<b64url(bookId)>/book.json` | `OfflineBook`（章节列表 + 元信息） | 无 TTL；小说区 1 GiB 软上限 |
| `offline/novel/<bookKey>/<b64url(chapterId)>.json` | `{id,title,paragraphs,fetchedAt}` 明文 | 无 TTL |
| `offline/video/<b64url(seriesId)>/series.json` | 剧集列表 + 档位 + 进度 | 无 TTL；短剧区 3 GiB 软上限 |
| `offline/video/<seriesKey>/<b64url(episodeId)>.mp4` | **明文 mp4** | 无 TTL |
| `reader_chapters/<b64url(chapterId)>.json` | `{id,title,paragraphs,fetchedAt}` | 300 文件（mtime）、7 天 stale、内存 LRU 8 |
| `backend/src/<videoId>.mp4` | **CENC 密文** | 总预算 128 MiB，最旧优先 |
| `backend/src/<videoId>.<ext>.key` | hex 密钥 sidecar | 随视频删 |
| `backend/src/<videoId>.<ext>.variant.json` | `{name,width,height,short_edge}` | 随视频删 |
| `Application Support/libCachedImageData.db` + `Library/Caches/libCachedImageData/` | 封面图 + sqflite 索引 | 120 对象 / 7 天；启动 >40 MB 裁到 25 MB |
| `backend/config/` | 设备池 + 运行时 config | **不是缓存**，删了要重新注册设备 |
| `backend/rust.log`、`offline/diag.log` | 排障日志 | 轮转；可随时删 |

### 6.2 隔离不变式

1. 离线区不参与任何自动淘汰 / TTL / 体积裁剪；`AppCache.clear()` 只清自动层，**永不碰 `offline/`**（有回归用例）。
2. 小说 / 短剧两个离线区相互独立：目录、manifest、统计、清空互不影响。
3. 软上限：小说 1 GiB、短剧 3 GiB，超限阻止新任务并引导去「我的 → 缓存」清理。
4. 下载任务同一时刻只有一个；切后台在当前章/集结束后暂停，回前台不自动继续；删除前先取消任务/排队项。
5. manifest schema 读不懂时当「没有缓存」，不删文件。

清理入口：「设置 → 存储」只清自动缓存；离线 pinned 区统一在「我的 → 缓存」页删除/清空，入口是右下角悬浮按钮。

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

---

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

**明确不做**：流式起播（M1）、画中画 / HDR / 后台播放 / AirPlay / 锁屏媒体信息、弹幕、听书、漫画、评论/段评、登录、
在线清晰度切换（C1 依赖 M1）、秒级播放进度、iOS 后台下载。

**当前限制**：

1. 首次打开必须联网完成设备注册（`log.snssdk.com`），失败停在「阅读环境启动失败」。
2. 短剧起播要等整集下载进内核缓存（流式回环未做）；`mode=cached` 命中可秒开。
   断网后第一次取流仍可能耗到内核重试预算（黑洞网络约几十秒），之后进入「疑似离线」
   快速失败（见 §5.7），用户手动重试会再试一次完整网络。
3. 清晰度：在线播放固定「当次上游最高可解码档」；720P 上限只作用于**离线整剧下载**（默认 720P，可设最高/1080P/480P）。
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
| `lib/features/cache/offline_downloader.dart` | 离线下载引擎（单任务状态机 + 队列） |
| `lib/features/video/network_health.dart` | 会话级「疑似离线」标记：断网后切集快速失败、手动重试强制联网 |
| `rust/src/endpoints/video.rs` | 取流、选档、整集下载、缓存淘汰、`/src` 解密 |
| `rust/src/endpoints/{book,content,dhcontent}.rs` | 详情、目录、正文（DH / AES）与批量正文 |
| `.github/workflows/ci.yml` / `Makefile` | 质量门禁 |
