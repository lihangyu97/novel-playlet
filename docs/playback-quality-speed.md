# 视频播放增强：缓存切集「准备」优化 / 自选清晰度 / 倍速播放

> 分支：`feat/lhy/playback-quality-speed-plan`（从 `main` 切出）
> 状态：**方案已评审**；播完自动续播控制条、全屏底部控制条贴底两个修复已实现（§4.4），其余按 §5 排期（2026-11-07）
> 关联：[video-playback.md](video-playback.md)（M0 决策与边界）、[offline-cache.md](offline-cache.md)（离线缓存）、`origin/feat/lhy/streaming-media-plan:docs/streaming-media-m1.md`（M1 流式起播，方案定稿未实现）
> 口径：**已验证**＝当前代码/测试可直接读出；**待实测**＝需要真机或真接口确认。行号以 `main`（`86ff328`）为准。

## 0. 结论速览

1. **「正在准备视频…」不是一件事**，要按两种「已缓存」分开看：
   - **离线 pinned 区命中**（手动整剧下载）：不联网，等待的是 `AVPlayer` 初始化 + 平台视图 + 首帧（估算几十~几百 ms），但 UI 从切集第一帧就整屏 spinner、且旧画面已被销毁，所以「准备」的感知被放大——这是用户报告症状的主因。
   - **内核自动缓存区命中**（看过就有的 `backend/src` 密文缓存）：**仍然要打上游**。`handle_video` 无论缓存是否命中都会请求 `video_model`，还会为客户端根本没用的 `variants` 再拉 fallback 列表，然后才在本地命中缓存——每次切集 1~3 个 HTTPS RTT，这是「已缓存为什么还要准备很久」的结构性根因；断网时这些集甚至放不出来。
2. **当前没有固定清晰度**：在线（非 stream）与离线整剧下载走同一条 `/api/v1/videos/{id}`，内核按「宽×1e9 + 高×1e6 + 码率（h264/avc1 仅完全同分 +1）」选当次上游的**最高可解码档**（通常 1080P，待真接口确认）；`bytevc2` 整档过滤，无播放失败降档。`variants` 只在 `mode=stream` 返回，非 stream 成功响应没有，Dart 正常路径拿不到、也播不了（每档 URL 是 CENC 密文，只有内核 `/src` 或未来的流式会话能解）。
3. **自选清晰度最好分期做**：先做「下载/离线清晰度上限」（内核 `?max_height`，不依赖 M1，约 2~2.5 人天），M1 落地后再做「在线换档」（按 variant 开流式会话，换档 = 重开会话 + seek 回原位，约 2.5~3.5 人天增量）。在当前 M0「整集下载后播」下做在线换档，换一次档就要重新下整集（10~30MB），体验很差。
4. **倍速**：1.5x / 2.0x 零风险；3.0x API 层可行，唯一硬风险是 iOS 插件在 `AVPlayerItem.canPlayFastForward == false` 时**静默把 >2x 降到 2x**（`video_player_avfoundation` 2.12.3）。离线本地文件一定满足快进条件，在线 `/src` 回环（progressive HTTP mp4）需真机确认。音频默认 `timeDomain`（iOS 15+），3x 不变调；**不需要原生改动、不需要换插件**。已拍板：保留 3x，在线被 clamp 时按 2x 播、不 fork 插件（§6.1）。
5. **建议顺序**：先做纯 Dart 的「切集感知优化 + 倍速」（1 个 PR，收益立刻可见），再做「`mode=cached` 免上游探测」（Rust 小改，根治自动缓存慢/断网不可播），随后做「离线清晰度上限」，等 M1 再做在线清晰度。具体拆分见 §5。

---

## 1. 问题 1：已缓存的短剧，切集为什么还出现「正在准备视频…」

### 1.1 先分清两种「已缓存」

| | (a) 离线 pinned 区 | (b) 内核自动缓存区 |
|---|---|---|
| 目录 | `<Application Support>/offline/video/<seriesKey>/<episodeKey>.mp4`（明文） | `<Application Support>/backend/src/<videoId>.mp4/.m4s/.ts`（CENC 密文 + `.key` sidecar） |
| 谁写 | 用户手动「整剧下载」：`videoSource` → 回环 `/src` 明文流 → `.part` → `commitEpisode` | 播放/下载时内核 `download_and_save` 自动落盘；128MB 预算按最旧异步淘汰 |
| 播放器怎么用 | `VideoPlayerController.file`（`lib/features/video/video_player_page.dart:128-134`） | 仍走 `api.videoSource` → `VideoPlayerController.networkUrl(http://127.0.0.1:<port>/src/...)`（`:146`、`:150-153`） |
| 切集时是否联网/碰 Rust | 否 | **是**（每次都要上游取流探测） |
| 断网时 | 可播 | **不可播**（上游失败 → 报「该集未离线缓存」，即使 `src/` 里文件在） |
| 淘汰 | 永不自动淘汰，仅用户删除 | 128MB 上限（约 5~10 集），看别的剧时会被淘汰 |

代码里的优先级是「离线 pinned → 内核自动缓存 → 网络」（`lib/features/video/offline_playback.dart:6-10`、`docs/offline-cache.md:77`）。

### 1.2 「正在准备」到底在等什么

**已验证**：spinner 由 `_loading` 控制，`_open()` 一进来就 `setState(_loading = true)`（`video_player_page.dart:108-114`），只有 `controller.initialize()` 成功后才清除（`:200`、`:210-211`）。显示条件是 `_error == null && (_loading || controller == null || !isInitialized)`（`:591`、文案 `:599`）。

```
点「下一集」/选集/自动连播
  ├─ _disposeController()              旧画面立刻消失（黑屏开始，:105）
  ├─ setState(_loading = true)         第一帧就是「正在准备视频…」（:108-114）
  ├─ await 离线 pinned 探测              path_provider + 2 次 stat（1~5ms，:119/:241-261）
  ├─ 分支 A：离线命中
  │    └─ controller.initialize()       本地文件 AVPlayer 初始化（待实测：约 50~300ms，:200）
  └─ 分支 B：未命中离线（内核自动缓存 / 真网络）
       ├─ await api.videoSource()       上游取流 1~3 个 RTT（200ms~1.5s+，:146）
       └─ controller.initialize()       回环 HTTP 初始化 / Range 解密（待实测）
  → setState(_loading = false)          spinner 消失（:210-211，此时还没 play、没建平台视图）
  → play() → 平台视图创建 → AVPlayer 首帧
```

所以：

- **离线 pinned 命中**：真正常规成本只有「离线探测 IO + AVPlayer 初始化 + 平台视图 + 首帧」，**没有网络、没有内核**；「准备」的全部来源是播放器初始化本身 + 没有任何旧画面兜底。
- **内核自动缓存命中**：还要加上「上游取流探测」这笔网络成本（见 1.3），这才是「已缓存还要等很久」的根因。
- 另外 spinner 消失后到真正出画面之间还有一段黑屏（平台视图创建 + 首帧），所以观感是「黑屏 → 正在准备视频… → 突然出画面」。

### 1.3 三个结构性原因（按影响排序）

**① 自动缓存命中仍然打上游（根因，已验证）**

`handle_video` 在非 stream 模式下**无条件**先请求 phoenix `multi_video_model`（`rust/src/endpoints/video.rs:153-158`），随后才调 `download_and_save`；后者命中本地缓存时只做一次 stat + `.key` sidecar 校验就返回 `/src`（`:1399-1423`）。也就是说「缓存命中」省掉的只是整集下载，**上游往返一分没省**。

更浪费的是：响应里的 `variants` 会在 `download_and_save` 之前就被计算（`:180-190`），`extract_stream_variants` 会为每个带 `fallback_api` 的 model 再拉一次 fallback 列表（`:507-530`、`:535-559`）——而 Dart 侧 `VideoSource.variants` 没有任何消费者，非 stream 成功响应也根本不带 `variants`（`:195-209`）。**每次切集至少多 1 个上游 RTT 是纯浪费**。

顺带一个断网 bug：`_open` 里 `resolveOfflineEpisode(offline: false)` 恒传 false（`video_player_page.dart:121-125`），自动缓存命中集在飞行模式下会先等 `videoSource` 失败（默认 20s，取流接口 120s 超时），最后被错误提示成「该集未离线缓存」（`:159-177`、`offline_playback.dart:34-36`）。

**② 切集第一帧就销毁旧画面 + 整屏 spinner + 隐藏控制条（感知放大，已验证）**

`_open` 第一步 `_disposeController()`（`:105`），随后 `setState(_loading=true)` 并隐藏 chrome（`showChrome = !_loading && _error == null`，`:529`）。用户看不到上一集末帧、也看不到剧名/返回键，只有黑底 spinner。真实耗时可能只有 200~300ms，但观感是「卡了一下」。

**③ 固定 IO 与重复读盘（小头，已验证）**

- `OfflinePaths.root()` 没有进程内缓存，每次切集重新走 `path_provider`；`path_provider_foundation` 还会 `Directory.create(recursive: true)`（`lib/core/storage/offline/offline_paths.dart:21-24`、`:42-43`）。`episodeFileIfCached` 又 `exists()` + `length()` 两次 stat（`offline_series_store.dart:92-100`）。合计约 1~5ms。
- Rust `/src` 的每个 Range 请求都重读一次 moov 判断 CENC 状态（`rust/src/endpoints/video.rs:1798`、`:1723-1735`），起播/seek 时每个请求几 ms 级。
- 入口侧：详情页是「网络优先，失败才读离线 manifest」（`video_detail_providers.dart:31-69`），「我的 → 最近观看」续播前还要 `await api.videoEpisodes`（`mine_drama_panel.dart:115`），离线时会先把整段等待算进「点开要等」。

### 1.4 优化方案（按收益/成本排序）

#### P0-1 内核加 `mode=cached`：缓存命中不再打上游（Rust + Dart，约 0.7~1 人天）

给 `/api/v1/videos/{id}` 增加只查本地、**完全不请求上游**的分支：

```text
GET /api/v1/videos/{id}?mode=cached
命中：{ "video_url": "/src/<id>.<ext>", "cached": true,  "variant": {...} | null }
未命中：{ "cached": false }
```

- 查找规则：按 `<id>.mp4/.m4s/.ts` 找 `src/` 文件（文件名规则与 `download_and_save` 一致，`video.rs:1375-1388`）；密文文件必须有可读 `.key` sidecar（否则 `/src` 会 503，`:1801-1813`）。
- Dart 播放顺序改为：离线 pinned → `mode=cached` 探测 → 命中直接播 `/src`；未命中才 `api.videoSource`（miss 时多一次进程内 FRB 调用，<1ms）。
- **收益**：自动缓存命中路径去掉 1~3 个 RTT（-200ms~-1s+），坏网络下从「超时/错误」变成秒开；**同时让自动缓存区断网可播**。
- **不改 FRB 绑定、不改 pubspec/插件**。参考 M1 方案 §4.4（`origin/feat/lhy/streaming-media-plan:docs/streaming-media-m1.md`）。
- **风险**：探测命中但文件随后被淘汰/半截 → AVPlayer 初始化失败；回退策略是失败后走一次正常 `videoSource(refresh: true)`，不要缓存探测结果。与「清晰度 marker」的衔接见 §3.1。
- **测试**：Rust mock 上游断言 `mode=cached` 命中时上游请求数为 0；Dart 覆盖命中/未命中/损坏回退。

#### P0-2 切集感知：保留旧画面 + 延迟 spinner + 保留控制条（纯 Dart，约 1~1.5 人天）

- `_open` 不再第一步 dispose 旧 controller：旧 controller 先 `pause()`、留在最底层继续渲染最后一帧；新 controller `initialize()` 成功、赋值后再下一帧移除旧 widget 并 dispose。
- spinner 延迟 200~300ms 才出现（`Timer`/`AnimatedOpacity`）：本地文件通常在新画面出来前就完成了，用户不再看到「正在准备」闪烁。
- 加载期间保留顶栏（返回、剧名、集名），`showChrome` 条件从 `!_loading` 放宽为 `_error == null`。
- 错误页出现时必须清掉旧画面，避免盖住错误信息；旧 controller 立即 pause 防止双声。
- **收益**：不减少真实耗时，但**消除「黑屏 + 正在准备」的感知**；对离线命中尤其明显，基本等于「秒切」。
- **风险**：platformView 短暂叠两层原生视图，需真机验证全屏/转屏合成；多一份 AVPlayer 的瞬时内存。
- 现有 golden 不含播放页，不影响基线；建议给播放页补一个 FakeController 的 widget 测试（见 §4.4）。

#### P0-3 预取下一集（纯 Dart，约 1~1.5 人天，可与 P0-2 同 PR）

当前集播放超过 3~5s 或进度 >30% 后，后台预取 `episodes[_index+1]`：

- 第一档：先 `mode=cached` 探测，未命中再 `videoSource(nextId)`，把结果存进页内 LRU（带 TTL），切集时命中则跳过取流；
- 第二档（可选）：连 `VideoPlayerController` 一起 `initialize()` 预建，切集时只 `play()` + 上屏。要复用现有 `_generation` 竞态保护，跳集/离页时 dispose。
- **收益**：消灭「下一集按钮 / 播完自动下一集」的取流与初始化等待；缓存未命中时把整集下载移出关键路径（-1s~-10s+）。
- **风险**：流量（已确认允许预取触发整集下载；仍建议只在当前集已播 3~5s 后触发，避免秒退也下整集）、内核 128MB 淘汰（预取可能挤掉别的集，但当前集 mtime 新，风险低）、预取后 URL 失效需 catch 回退。

#### P1 顺手项（可与上面合并）

| 项 | 做法 | 收益 |
|---|---|---|
| 取流跳过 variants | `handle_video` 支持 `variants=0`（或 `mode=cached` 天然跳过）；播放页调用时带上 | 非缓存首次播放 -1 个 RTT |
| 离线路径内存缓存 | `OfflinePaths` 缓存 root 路径；`episodeFileIfCached` 用一次 `stat()` 替代 `exists+length` | -1~5ms/切集 |
| `/src` 请求级 CENC 状态缓存 | 把 `cache_cenc_state` 并入现有索引缓存（按 path+len+mtime 失效） | seek 手感，几 ms/请求 |
| 入口侧离线优先 | 详情页 `series.json` manifest-first、最近观看用 manifest 组装 episodes 再 push | 弱网/离线入口 -数秒 |

#### 不做 / 后置

- **AVPlayer `replaceCurrentItem` 复用 / 自写薄 Swift 插件**：能省 ~100~200ms，但要 fork 插件或改 `ios/`，维护成本高，当前收益不值；先做 P0-1~P0-3。
- M1 流式回环：治的是「冷缓存首帧」，对「已缓存切集」的收益主要是其中的 `mode=cached`——**建议先把 `mode=cached` 从 M1 里拆出来单独做**。

---

## 2. 问题 2：现在缓存/在线播放的默认清晰度是什么

### 2.1 结论

**没有固定档位，也没有用户可见的「清晰度」概念。** 在线播放（非 stream）与离线整剧下载走同一条 `/api/v1/videos/{id}` 非 stream 路径：

1. 内核在**当次上游返回的档位列表**里，按 `宽×1e9 + 高×1e6 + 码率（h264/avc1 同分 +1）` 从高到低选**最高的一档可解码档**（`rust/src/endpoints/video.rs:833-890`）；`bytevc2`（H.266 类、无解码器）整档排除，h265/bytevc1 照收。只在「URL 解不出来」时试下一档，**没有播放失败后的自动降档**。
2. 选中的那一档被**整集下载**进 `backend/src/<video_id>.<ext>`（CENC 密文 + `.key` sidecar），`/src` 按 Range 解密后给 AVPlayer 播（`video.rs:1359-1501`、`:1787-1876`）。
3. **离线整剧下载逐集复用同一个 `api.videoSource()`**，把 `/src` 明文流落盘成 `offline/video/<seriesKey>/<episodeKey>.mp4`；落盘的就是在线默认那一档。manifest 没有质量字段，UI 不显示、不可选（`lib/features/cache/offline_downloader.dart:806-830`、`offline_series.dart:6-97`）。
4. 具体命中哪一档由该集上游响应决定：非 stream 只请求 phoenix `multi_video_model`（`video.rs:153-158`）；代码注释记录的实测分布是「shortplay 自身列表到 720P，1080P 只在 phoenix 的 `fallback_api` 里，phoenix 低档常是解不了的 bytevc2」（`:108-113`、`:500-506`）。因此**通常是最高可解码档（很可能是 1080P），但必须在真接口上对拍确认**。

### 2.2 为什么 UI 看不到也选不了

| 环节 | 事实 | 证据 |
|---|---|---|
| 非 stream 成功响应 | **没有 `variants` 字段**；只有下载失败兜底才返回带 variants 的 `source` | `video.rs:195-214` |
| stream 响应 | 返回 `url + key_hex + variants`（每档 `name/width/height/url/key_hex`，高→低） | `video.rs:180-193`、`:507-582` |
| variants 的 URL 能直接播吗 | **不能**：是解密后的 CDN 地址，但内容是 CENC 密文；每档有自己 `spade_a` 推导的 key，只有内核 `/src` 或 M1 流式会话能解 | `video.rs:431-468`、`:986-1022` |
| Dart 现状 | 正常路径 `VideoSource.variants` 恒空；`VideoVariant` 连 `key_hex` 都没解析；全 `lib/` 没有消费者 | `lib/data/models/video_source.dart:26-57`、`lib/data/api/api_client.dart:152-182` |
| 文档口径 | `docs/video-playback.md:15` 说「variants 仍在数据层保留，后续再开」——实际非 stream 不返回、Dart 拿不到，需要同步修正 | 同上 |

**一句话**：Rust 已经有算出全量档位的能力，但 iOS 客户端既没有拿到（非 stream 不返回）、也没有播放通路（每档密文）——「自选清晰度」在当前架构里是从 0 到 1。

---

## 3. 自选清晰度的三个方案

### 3.1 方案 A：内核 query 按档下载（M0 现状可用）

```text
GET /api/v1/videos/{id}?quality=auto          # 现状：最高可解码档（默认）
GET /api/v1/videos/{id}?quality=720P          # 按显示名选（高→低列表里的 name）
GET /api/v1/videos/{id}?max_height=720        # 按短边设上限（下载清晰度用，最稳）
GET /api/v1/videos/{id}?variants=1            # 顺带返回 variants（给面板用）
```

- 参数存在时并发请求 shortplay + phoenix（复用 stream 分支结构，`video.rs:114-152`），用 `extract_stream_variants` 合并全量档，按显示名或短边挑一档，喂给 `download_and_save`。
- 响应补 `applied_variant: {name, width, height, short_edge}` 与 `quality_fallback: bool`（请求档不可用时回退）。
- **缓存必须按档区分**：当前缓存名是 `<video_id><ext>` + `.key`，只看文件存在——不区分档会「请求 720P 命中 1080P」。推荐**单文件 + 档位 marker**：`<video_id><ext>` + `.key` + `.variant.json`（或把档位并进 key sidecar）；命中时校验 marker 档位，不匹配就重下覆盖。这样 128MB 预算/淘汰逻辑完全不用改。**不建议每档一份**（128MB 下可缓存集数减半、淘汰会误删在追的档）。
- `refresh=1` 要连同 marker 一起删；per-file 锁已有（`video.rs:1389`），注意并发/淘汰时序测试。
- **缺点**：换档 = 重新整集下载（10~30MB，等 10s+），必须显示「切换清晰度下载中」；播放位置要自己保存/恢复。
- **工期**：Rust 1.5~2.5 + Dart 1~1.5 + 离线/设置 1~1.5 + 真机 0.5~1 ≈ **4~6.5 人天**（只做「在线换档」约 2.5~3.5；只做「下载/离线上限」约 2~2.5）。

### 3.2 方案 B：M1 流式会话按 variant 播放（长期正解）

M1 落地后（`open_media_session(url, key_hex)` 可用）：

- 播放走 M1 的 `/media/<token>` 流式解密；`mode=stream` 已经返回 `url + key_hex + variants`（`video.rs:180-193`，已验证）；
- 默认「自动」= 合并后的 `variants[0]`；显式档按 name 匹配该集自己的 variants，匹配不到回退默认；
- 换档 = 关旧会话 → 用新 variant 开新会话 → `seek` 回原位置 → 恢复播放（fqapp 已验证同一语义：`inline_video_playback.dart:489-554`）；
- **需要先对拍的高风险点**：stream 的 `video_url` 来自 shortplay 最高档（≤720P），而 `variants[0]` 可能是 phoenix fallback 的 1080P——M1 若直接用 `video_url` 开会话，会出现「面板第一行 1080P，实际播 720P」。M1 实施时应把「自动档」改成用合并后的 `variants[0]`（或按 `quality` 参数挑）。
- **前置成本**：M1 本体 2~4 人天（C 构建风险）；清晰度增量约 2.5~3.5 人天。FRB 需重生成；`VideoVariant` 要补 `keyHex`。
- **缺点**：M1 未落地前不可用；写穿缓存仍会按默认最高档下 2× 流量（除非复用 A 的档位口径）。

### 3.3 方案对比

| 维度 | A：内核 query 按档下载 | B：M1 会话按档播 | C：分期（推荐） |
|---|---|---|---|
| 前置依赖 | 无（M0 可用） | **M1 必须先完成** | C0 无；C1 依赖 M1 |
| 在线换档体验 | 重新整集下载（10s+） | 重开会话（秒级），seek 回原位 | C1 同 B |
| 离线/缓存质量可选 | ✅ | ❌（写穿仍最高档） | ✅ C0 解决 |
| FRB 重生成 | 不需要（query 透传） | 需要 | C0 不需要；C1 跟 M1 |
| 工期（增量） | 4~6.5 人天 | 5~7.5 人天（含 M1） | 2~2.5 + (M1 + 2.5~3.5) |
| 主要风险 | 换档慢/位置恢复/HEVC 无降档 | C 构建、换档花屏、2× 流量 | 分期风险，每期独立验收 |

### 3.4 推荐：方案 C（分期）

**C0（现在做，2~2.5 人天，不依赖 M1）——「下载/离线清晰度上限」**

- 内核 `?max_height=` 按短边选档（复用非 stream 下载链路），下载的 `/src` 即该档；缓存加档位 marker。
- Dart 全局设置「下载清晰度」：**默认 720P**，可选 最高 / 1080P / 720P / 480P（`shared_preferences` 单值），只影响**离线整剧下载**；在线播放行为 C0 阶段不变（默认在线档在 C1 才切到 720P）。
- 离线 manifest 记档位（剧级「请求口径」+ 集级「实际档位」；旧 manifest 缺字段按「最高/未知」处理，不 bump schema）；缓存中心显示「已缓存 · 720P」；改档需二次确认后删除重下，不后台偷换。
- 收益：立刻解决 3GB 离线预算/流量不可控；不动播放主链路，零播放 UX 风险。

**C1（M1 落地后做，2.5~3.5 人天增量）——「在线换档」**

- 按实际 variants 渲染面板（`variants.length <= 1` 时隐藏入口，对齐官方 gate）；**默认 720P**，不再是「自动最高档」；面板保留「自动（最高）」作为用户可选项。
- 「720P」口径：该集 variants 里短边 ≤720 的最高档；没有 720P 时取 ≤720 的最高档，再没有就取最低可用档；响应的 `applied_variant` 显示实际命中档，避免「选 720P 实际 480P」无提示。
- 按剧记忆用户选择（只记显示名，会话内；换剧不串档），持久化偏好另存全局默认（默认 720P）。
- 换档 = 重开会话 + seek 回原位；失败回退原档位；写穿缓存复用 C0 的档位口径；
- 同时修掉 §3.2 的「自动档口径不一致」。

**产品策略建议**

| 项 | 决策 |
|---|---|
| 默认在线档 | **默认 720P**（缺档回退：≤720 的最高档 → 最低可用档）；「自动（最高）」保留为可选项，不做默认 |
| 移动网络自动降档 | 后置。仓库无 connectivity 依赖且 `CONTRACTS.md` 禁新增依赖；默认 720P 本身已降低流量，暂不需要按网络切档 |
| 在线清晰度记忆 | 按剧、只记显示名、会话内有效（不持久化），换剧不串档；默认 720P |
| 下载清晰度 | 全局持久化，**默认 720P**（「我最多接受多高」与具体剧无关） |
| 换档位置 | **必须保留**：保存 position + playing，新 controller/会话就绪后 seek 回原位 |
| 离线显示质量 | 显示「已缓存 · 720P」，改档走显式「重新缓存为 1080P」确认，不做同剧多档并存 |

**UI 草案**（与倍速共用控制条第三行，见 §4.3）

- 倍速 chip 在左（`1.0x`，高频控制），清晰度 chip 在右（`720P`/`1080P`，偶发设置），全屏按钮最右；
- 点清晰度 chip 开底部弹层：`720P（默认） / 1080P / 480P / 自动（最高）`，当前档高亮；离线集显示「离线 · 720P」并置灰（提示「删除离线缓存后可切换」）；
- 切换中在视频区显示轻量「切换清晰度…」而不整屏 spinner；失败回滚原档位并提示。

---

## 4. 倍速播放（1.0x / 1.25x / 1.5x / 2.0x / 3.0x）

### 4.1 可行性结论（已验证）

依赖版本：`video_player 2.14.1` / `video_player_avfoundation 2.12.3`（`pubspec.lock:756-779`）。

| 结论 | 证据 |
|---|---|
| Dart `setPlaybackSpeed` 只校验 >0，无上限 | `video_player.dart:881-892` |
| iOS 原生写 `AVPlayer.rate`；暂停/seek 不会冲掉目标速度；play 时会重新 apply | `VideoPlayer.swift:333-336`、`:507-520`、`:617-634`；`video_player.dart:797-800` |
| **>2.0 且 `canPlayFastForward == false` 时静默降为 2.0**（不抛错） | `VideoPlayer.swift:620-629` |
| 文件型 asset ready 后 `canPlayFastForward == YES`（Apple QA1772）→ **离线离线文件 3x 一定生效**；在线 `/src` 是 progressive HTTP mp4，需真机确认 | Apple QA1772 |
| 音频不变调：插件从未设置 `audioTimePitchAlgorithm`，iOS 15+ 默认 `timeDomain`（支持 1/32~32 倍速、做音高修正） | 插件源码 grep 为 0；Apple 文档；`ios/Runner.xcodeproj` deployment target 15.0 |
| platformView 与倍速无关（只改 AVPlayer.rate，不经过纹理拷贝） | `VideoPlayerPlugin.swift:176-188`、`FVPNativeVideoView.m` |

**结论**：1.5x/2x 直接做；3x 在离线文件上确定可用，在线上回环「大概率可用、需真机验证」；如果被 clamp，产品二选一：在线最高 2x、3x 仅离线，或 fork 插件去掉 clamp（约 10 行，但引入 fork 维护成本，不建议）。**不需要额外原生改动、不需要换插件。**

### 4.2 实现设计

1. **状态单一来源**：新增 `lib/features/video/playback_speed.dart`，`NotifierProvider<PlaybackSpeedController, double>`，根 `ProviderScope` 存活；`shared_preferences` 单 key `video_playback_speed_v1`，白名单 `[1.0, 1.25, 1.5, 2.0, 3.0]`，默认 1.0。持久化范式照抄 `reader_settings.dart` / `theme_settings.dart`（`_userChanged` 防异步旧值覆盖）。
2. **apply 时机**：所有 controller 都只从 `_startController` 创建；在 `await controller.initialize()` 之后、`play()` 之前 `setPlaybackSpeed(provider)`（暂停态 Dart 只存值不下发，`play()` 时必然重新 apply）。换集/自动连播因此自动继承倍速。
3. **运行中改速**：`ref.listen(playbackSpeedProvider, ...)` 对已初始化 controller 无条件调 `setPlaybackSpeed`（暂停时也要调，否则 controller 内部还是旧值，恢复播放会按旧速）。
4. **换清晰度/换源**：必须复用 `_startController`（这是两功能唯一强制的共享契约），否则新 controller 会回到 1.0x。
5. **UI**：底部控制条第三行左侧加 `1.0x` 文字 chip，点击开底部弹层（标题「播放速度」，5 个选项，复用选集弹层的选中/未选样式）；chip 文案来自 provider，不读 controller（换集瞬间旧 controller 已 dispose）。控制条隐藏时可选在右上角显示小 `2.0x` 角标（P2，可先不做）。
6. **布局**：左「选集 + 倍速」、右「清晰度（有 variants 时）+ 全屏」；390pt/375pt 屏无重叠，320pt 窄屏把清晰度收进「更多」。竖屏/横屏全屏共用同一个 `_buildBottomBar`，一处实现两处生效。

### 4.3 风险与真机验证

| 风险 | 应对 |
|---|---|
| 在线 `/src` 3x 被静默 clamp 成 2x，UI 显示 3x 实际 2x | 真机用「30s 墙钟 Δposition」测量有效倍速（≥2.85 视为生效，≤2.1 视为 clamp）；命中则按 §4.1 决策 |
| 3x 画面跳帧/I 帧顿挫（QA1772 明确 >2x 可能降级解码） | 真机多看几部；产品拍板是否保留 3x |
| 3x 音频 timeDomain 音质一般（人声中质量） | 真机听感确认；不建议本期改 `spectral` |
| 缓冲 stall 后 AVPlayer 回落、插件不主动重设 | 加固：listener 检测 `isPlaying` false→true 且 `value.playbackSpeed != provider` 时补 apply |
| seek 后掉速（个别片源） | 同上，`_seekTo` 后补一次 apply |
| 全屏/转屏/切集/自动连播丢速 | 均走 `_startController`，widget 测试锁「新 controller 收到最新倍速」 |
| 全局持久化导致「换剧仍 3x」 | 文档写清；有反馈再加按剧覆盖（+0.5 人天） |

**工期估算**：provider + 弹层 + chip + 页面接入 + 单测 ≈ 2.5~3 人天；FakeController 页面级测试 +0.5~1；真机验证（3x 在线/离线、音频、弱网、20 分钟温升）1~1.5；合计约 **4~5 人天**，可与清晰度并行（chip 共享文件归属 +0.25~0.5）。

### 4.4 控制条行为修复（本分支已实现）

1. **播完自动续播不再弹控制条**：`_open` 增加 `autoAdvance` 参数；`_onTick` 自动进下一集时传 `autoAdvance: true`——`_controlsVisible` 保持 false，`_startController` 也不再启动自动隐藏计时。控制条只在首次进入播放页、或用户点屏幕（`_toggleControls`）时出现；手动上/下集、选集弹层仍按当前显隐状态。
   - 改动：`lib/features/video/video_player_page.dart` 的 `_open` / `_startController` / `_onTick`。
2. **全屏横屏底部控制条贴底**：底部控制条的 `SafeArea` 改为 `bottom: !_fullscreen`——竖屏仍避让 Home 指示条，横屏全屏不再避让，渐变与控制条直接贴到屏幕最底边；顶部控制条仍避让状态栏/刘海。
   - 改动：`video_player_page.dart` build 里底部 `Positioned` 的 `SafeArea`。
3. **验证**：`flutter analyze --fatal-infos lib/features/video` 无问题；`flutter test test/ui/mine_test.dart test/ui/video_test.dart test/offline_playback_test.dart` 全绿。播放页目前没有 widget 测试（无 controller 工厂 seam），自动续播与全屏贴底仍需真机回归；后续 S1 加 FakeController seam 时补页面级测试。

---

## 5. 实施计划（建议按 PR 拆分）

| 阶段 | 内容 | 依赖 | 估时 | 验收 |
|---|---|---|---|---|
| **S0（已实现）** | 控制条：播完自动续播不弹控制条；全屏横屏底部控制条贴底、取消底部安全区避让（§4.4） | 无 | — | `flutter analyze` + 相关 UI 测试通过；真机待回归 |
| **S1（纯 Dart，先做）** | P0-2 切集感知（保留旧画面/延迟 spinner/保留顶栏）+ P0-3 预取下一集（允许整集下载）+ 倍速播放 | 无 | 4~5.5 人天 | 离线命中切集不再出现整屏「正在准备」；3x 真机生效（在线被 clamp 时接受 2x）；`flutter analyze` + `flutter test` 全绿 |
| **S2（Rust 小改，根治）** | `mode=cached` 免上游探测 + `variants=0` + 离线路径 IO 缓存 | 无 | 1.5~2.5 人天 | 自动缓存命中切集上游请求数=0；飞行模式可播；坏文件回退正常 |
| **S3（清晰度第一步）** | C0：内核 `?max_height` 按档下载 + 档位 marker + 全局下载清晰度设置（默认 720P）+ 离线 manifest 档位 + 缓存中心展示 | 无 | 2~2.5 人天 | 离线下载可限高；缓存中心显示实际档；旧缓存/旧 manifest 兼容 |
| **S4（等 M1）** | M1 流式起播（`streaming-media-m1.md`）→ C1 在线换档（默认 720P、按剧记忆、换档重开会话 + seek 回原位、自动档口径修正） | M1 | M1 2~4 + 2.5~3.5 | 在线换档位置不丢、失败回退原档；默认档与面板一致 |

**S1 建议先合**：它不依赖 Rust、风险最低、直接消除用户报告的两个症状中的第一个（「正在准备」观感）并交付倍速；S2 再根治「自动缓存仍打上游」，两者不会互相阻塞。

---

## 6. 决策与开放项

### 6.1 已拍板（2026-11-07）

| # | 决策 |
|---|---|
| 1 | **3x 接受**：保留 3.0x 选项；在线 `/src` 若被 clamp 按 2x 播（不在 UI 报错、不 fork 插件）。 |
| 2 | **清晰度默认 720P**：在线与离线下载都不再默认最高档；在线按剧记忆用户选择（只记显示名，会话内），下载清晰度全局持久化、默认 720P。 |
| 3 | **预取下一集允许整集下载**：缓存未命中时预取可以把整集下载移出关键路径（仍建议当前集已播 3~5s 后触发）。 |
| 4 | **控制条**：播完自动续播不弹控制条；全屏横屏底部控制条贴底、取消底部安全区避让（已实现，见 §4.4）。 |

### 6.2 仍待确认

1. **离线清晰度**：只做「下载上限」够不够；是否需要「同一剧重下为另一档」的入口。
2. **倍速持久化**：全局（推荐）还是按剧；控制条隐藏时是否显示倍速角标。
3. **3x 观感**：画面跳帧/I 帧顿挫是否可接受，只能真机看后由产品拍板（技术方案不阻塞）。

---

## 7. 真机 / 真接口验证清单

| # | 验证项 | 对应问题 |
|---|---|---|
| 1 | 真接口对拍：每集 shortplay/phoenix/fallback 各返回几档、显示名、短边、编码；非 stream 默认实际落在哪一档 | 清晰度 |
| 2 | stream `video_url` 与 `variants[0]` 是否同一档（M1 自动档口径） | 清晰度 |
| 3 | iPhone 13 上 HEVC/h265 各档可播；离线明文 mp4 与在线同编码 | 清晰度 |
| 4 | 换档后 seek 是否花屏/黑屏；位置恢复是否正确 | 清晰度 |
| 5 | 在线 `/src` 3x 是否生效（30s Δposition / Δwall ≈ 3.0）；离线文件 3x | 倍速 |
| 6 | 3x/2x 音频是否变调、音画是否同步；20 分钟温升/掉电对比 1x | 倍速 |
| 7 | 切集（上一集/下一集/选集/自动连播）在 3x 下保持倍速、不跳集 | 倍速 |
| 8 | 弱网/缓冲恢复后倍速是否保持 | 倍速 |
| 9 | 离线命中切集：spinner 是否还出现（S1 前后录屏对比） | 准备优化 |
| 10 | 自动缓存命中：抓包确认 `mode=cached` 后上游请求数=0；飞行模式可播 | 准备优化 |
| 11 | 内核缓存未命中/被淘汰时切集耗时（分段打点：离线探测 / videoSource / initialize / 首帧） | 准备优化 |
| 12 | 128MB 预算下预取下一集的淘汰行为；离线改档重下的磁盘峰值 | 综合 |
| 13 | 播完自动续播不弹控制条；手动点屏幕才出现；手动上/下集、选集切集行为不变 | 控制条 |
| 14 | 全屏横屏底部控制条贴到屏幕最底边（无 Home 指示条空隙）；竖屏仍避让底部安全区 | 控制条 |

建议打点方式：Dart `Stopwatch` + `offlineDiag()`（`lib/features/cache/offline_diag.dart`，已有时间戳落盘）；Rust `handle_video` 加 `Instant` 分级日志（上游/变体/下载命中/总耗时）；正式基线用 Instruments（Time Profiler + Points of Interest + Network）。

---

## 8. 文档与契约同步（实现时）

- `docs/video-playback.md`：修正「variants 数据层保留」的口径（非 stream 不返回）；更新「不做清晰度切换」决策记录；补倍速验收。
- `docs/offline-cache.md` §0 的「已缓存集切换无准备播放」与实现不符：应改为「无网络/内核准备；仍有 AVPlayer 初始化，UI 不应整屏 spinner」。
- 控制条行为（自动续播不弹、全屏贴底）已随 §4.4 实现，后续改动播放页时不要回退。
- `README.md` 功能表 / `CONTRACTS.md`：清晰度与倍速入口、依赖白名单（不需要新增 pubspec 依赖）、测试门禁。
- `PATCHES.md`：改动 `rust/` 时登记本地补丁。

## 9. 参考

- [video-playback.md](video-playback.md)：M0 决策、ATS/回环/渲染通路真机记录
- [offline-cache.md](offline-cache.md)：离线缓存两层架构、明文 mp4、下载流程
- `origin/feat/lhy/streaming-media-plan:docs/streaming-media-m1.md`：M1 流式起播定稿方案（`mode=cached`、`open_media_session`、写穿缓存）
- 同级 `fqapp` 参考实现：`inline_video_playback.dart:489-554`（换档/换源保留位置）、`drama_downloader.dart:824-856`（按上限选档）、`quality_memory.dart`（按剧记档名）
- Apple QA1772（`canPlayFastForward`）、Time pitch algorithm settings（`timeDomain`）
- 插件源码：`video_player-2.14.1/lib/video_player.dart`、`video_player_avfoundation-2.12.3/darwin/.../VideoPlayer.swift`
