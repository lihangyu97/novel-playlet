# 视频 M1：流式起播（边下边播）技术方案

> 状态：**方案定稿，未实现**（M0「先整集下载后播」已上线，见 [video-playback.md](video-playback.md)）。
> 目标：起播不再等整集下载；失败自动回退 M0；已下载内容零迁移。
> 预计工期：**2–4 人天**（含真机验证）。

## 1. 目标与不变量

1. **起播不等整集下载**：冷缓存首帧 P50 < 1s（M0 真机基线 1.1–1.5s，见 video-playback.md 5.1）。
2. **seek 即 Range**：拖动直接映射为 CDN Range 请求并现场解密，不预下载整集。
3. **磁盘不落明文**：本地缓存仍是 CENC 密文 + key sidecar，明文只存在于回环 socket。
4. **已下载的集零迁移**：缓存格式、文件名、淘汰逻辑不动，老内容直接可播。
5. **失败回退 M0**：流式会话打不开/解密失败/上游 4xx 时，退回「整集下载后播」。
6. **不新增 Flutter 依赖**：内核能力走现有 FRB 暴露，不引 `package:ffi`。

顺带修掉一个 M0 缺陷：**当前缓存命中也要先请求上游拿 URL/key**，断网时已缓存的集放不出来；
M1 增加 `mode=cached` 后，缓存集可完全离线播放。

## 2. M0 现状与缺口

| 能力 | 现状 | 位置 |
|---|---|---|
| 播放取流 | 默认非 stream：内核整集下载完才返回 `/src/...` | `lib/data/api/api_client.dart:127`、`rust/src/endpoints/video.rs:197` |
| `/src` Range 解密 | **已实现**（本地文件的 CENC 按 Range 解密） | `rust/src/endpoints/video.rs:1789`（`serve_src_file`）、`:2321`（`apply_cenc_index`） |
| 流式会话（CDN Range + 现场解密） | 代码已随 fqapp 拷入，但被 cfg 挡住 | `rust/src/desktop_media.rs`（583 行）、`rust/src/desktop_fetch.rs`（305 行）、`rust/src/lib.rs:39-42` |
| C 解密库 | **缺失**：`rust/native/crypto_core` 没拷进来 | `rust/build.rs` 目前只对 Windows 编 C |
| iOS 构建 | 静态库 `-force_load` + ATS 例外已就绪 | `ios/Flutter/{Debug,Release}.xcconfig`、`ios/Runner/Info.plist` |

结论：**不是从零做**。Rust 侧的会话/抓取/重试逻辑和「按 Range 解密」能力都在，缺的是
iOS 的 C 构建链、FFI 出口和 Dart 播放流程。

## 3. 方案选型

| | A：移植 fqapp 的 C 流式解密（推荐） | B：纯 Rust 重写 |
|---|---|---|
| 做法 | 拷 `native/crypto_core`，`build.rs` 加 Apple 目标，放宽 `desktop_*` 的 cfg，FRB 暴露 open/close | 在 axum 上新开 `/media/<id>`，远端 Range 抓取 + 自建 moov 索引 + 复用 `apply_cenc_index` |
| 复用 | 会话/端口/Range/重试/解密**全部现成**，Windows 已跑通 | 解密与 Range 逻辑可复用，但 moov 探测、跨块 sample、seek 边界要自己写 |
| 依赖 | 多一份 C（约 2300 行，其中 572 行是 Unlicense 的 tiny-AES） | 无 C 依赖，包体略小 |
| 风险 | C 构建/符号链接、iOS 阻塞网络库 | 边界 case 多，回归面大 |
| 工期 | **2–4 人天** | 3–5 人天 |

**结论：走 A。** fqapp 上已验证过，本仓库只差构建与接线；B 留作 A 遇到阻塞（例如 C 在
Apple 上编译不过）时的备选。

## 4. 详细设计

### 4.1 数据流

```
播放页 _open()
   │  1) mode=cached 探测（无网络）
   ├──► 命中：直接播 http://127.0.0.1:<axum>/src/<video_id><ext>（本地密文，Range 解密）
   │
   └──► 未命中：
        2) GET /api/v1/videos/{id}?mode=stream   （内核现已支持，返回远程 url + key + variants）
        3) FRB open_media_session(url, key)
             └─ desktop_media：起 127.0.0.1:<随机端口> 会话，返回 /media/<token>
        4) AVPlayer 播 http://127.0.0.1:<media端口>/media/<token>
             └─ 每次 Range 读取：desktop_fetch 拉 CDN Range → sp_stream 现场解密 → 回环写明文
        5) 首帧后按需「写穿缓存」：后台再调一次非 stream 接口，把整集密文落进 src/
```

### 4.2 内核改动清单

| 文件 | 改动 | 说明 |
|---|---|---|
| `native/crypto_core/`、`native/third_party/tiny_aes/` | **新增**（从 `~/workspace/fqapp/native` 选择性拷入） | 只拷 crypto_core 与 tiny_aes（Unlicense）；**不要**拷 `audio_tempo`（LGPL）；native/README 一并拷，保留来源与许可说明 |
| `rust/build.rs` | `windows` → `windows \| ios`；iOS 分支去掉 MSVC 专有 flag | `cc` crate 会自动用 `xcrun clang --target=arm64-apple-ios`；保留 `CBC=0 CTR=0 ECB=1`、`include("crypto_core")`；测试期可再加 `macos` 便于 host 跑 C 测试 |
| `rust/Cargo.toml` | `[target.'cfg(windows)'.dependencies] reqwest blocking` → `cfg(any(windows, ios))` | `desktop_fetch`/`desktop_media` 用的是 `reqwest::blocking`；iOS 需要同一 feature |
| `rust/src/lib.rs` | `desktop_fetch` / `desktop_media` 的 cfg 放宽到 iOS | 当前 `#[cfg(target_os = "windows")]` |
| `rust/src/desktop_media.rs` | `open()`/`close()` 抽成 `pub(crate)`；`OpenError` 转结构化错误（kind/status） | 现有 C 入口 `fq_desktop_media_open` 保留（Windows 用），新出口给 FRB 复用同一逻辑 |
| `rust/src/api/mod.rs` | 新增 `open_media_session` / `close_media_session` | 见 4.3；`open` 用 `tokio::task::spawn_blocking`，避免阻塞 tokio worker |
| `lib/src/rust/*`、`rust/src/frb_generated.rs` | 重新生成（勿手改） | `flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml`（2.13.0） |
| `rust/src/endpoints/video.rs` | 新增 `mode=cached` 分支 | 见 4.4；不请求上游 |

> 注意：`ios/Flutter/*.xcconfig` 的 `-force_load` / `DEAD_CODE_STRIPPING=NO` /
> `-Wl,-export_dynamic` 已经具备，C 静态库会随 Rust staticlib 一起链进主二进制，无需再改。

### 4.3 FFI 契约（FRB）

```rust
// rust/src/api/mod.rs
pub struct MediaSessionInfo {
    pub id: String,   // 会话 token，close 时回传
    pub url: String,  // http://127.0.0.1:<port>/media/<token>
}

/// 打开一个流式解密会话。url 为上游 CDN 密文地址，key_hex 为 16 字节内容密钥。
/// 失败返回可直接展示的中文原因（kind 通过前缀给出：connect/timeout/http/range/decrypt）。
pub async fn open_media_session(url: String, key_hex: String) -> Result<MediaSessionInfo, String>;

/// 关闭会话；重复调用幂等。页面 dispose / 换集时必须调用。
pub fn close_media_session(id: String);
```

Dart 侧建议新增 `lib/core/backend/media_session.dart`：包一层 `RustLib.instance.api.openMediaSession`
与 `closeMediaSession`，提供 `dispose()`，并保证 key/URL 不落日志。

### 4.4 缓存优先与离线播放

内核 `/api/v1/videos/{id}` 增加只查本地、不打上游的分支：

- `?mode=cached`：
  - 命中 `src/<video_id>.{mp4,m4s,ts}` 且 key sidecar 存在 → `200 {video_url: "/src/<file>", cached: true}`
  - 未命中 → `200 {cached: false}`
- 该分支**完全不请求上游**，因此缓存集可在断网下播放（key 从 sidecar 读）。

Dart 判定顺序：

```text
cached = api.mediaCached(id)          // mode=cached
if (cached != null) play(cached)      // 离线可用、秒开
else {
  src = api.videoSource(id, stream)   // 远程 url + key
  try   { s = openMediaSession(src.url, src.key); play(s.url) }
  catch { play(await api.videoSource(id)) }   // 回退 M0：整集下载后播
}
```

保留 M0 的 `videoSource(id)`（非 stream）不变：它同时充当**回退路径**和**写穿缓存**的下载器。

### 4.5 写穿缓存（看完即缓存，可选）

- 首帧出来后再后台调一次 `api.videoSource(id)`（非 stream）把整集密文落进 `src/`：
  - 复用内核现有的下载、key sidecar、128MB 预算与「同时最多 2 个下载」；
  - 与 `mode=cached` 天然幂等（命中即返回）。
- 代价：**约 2× CDN 流量**（流式已读的字节不会复用）。M1 接受这个代价，默认开；
  在「我的 → 存储」加开关，关掉就只流式不落盘。
- M2 可优化为「会话内 tee 密文」：desktop_media 抓到的 Range 顺带写入 `.part`，播放结束/关闭会话时补齐
  缺失区间再原子 rename，避免二次下载（设计见 §8）。

### 4.6 生命周期与回退

- 进播放页 open、换集先 close 旧的再 open、`dispose`/`PopScope` finally close；会话 id 存字段，避免泄漏。
- 会话上限已在 C/Rust 侧兜底（单会话 ≤8 socket、全局 ≤32）。
- 后台/锁屏：App 挂起会让回环 socket 失效，回前台 AVPlayer 报错 → 走「重开会话 → 仍失败则回退 M0」。
- 全屏/横竖屏切换不影响会话（同一个 `/media/<token>` URL）。

### 4.7 错误映射

| 失败点 | 表现 | 处理 |
|---|---|---|
| `open_media_session` kind=decrypt | 该集 CENC 不受支持（分片/多 KID/CBC） | 直接回退 M0（整集下载后播），不提示失败 |
| kind=connect/timeout | 网络 | 错误页 + 重试；重试仍失败回退 M0 |
| kind=http/range（403/404） | 上游地址过期 | 重新 `videoSource` 取流（可带 `refresh=1`）后再 open |
| AVPlayer 播放中报错 | 回环中断/会话被关 | 重开会话；失败回退 M0 |
| 回退也失败 | M0 下载失败 | 复用现有错误页（原因 + 可复制详情 + 重新下载这一集） |

### 4.8 安全边界

- 内容 key 只在核心内使用，经 FRB 传入即用，不写日志、不落 Dart 内存结构以外的地方。
- 会话 URL 带随机 32 字节 token，只监听 `127.0.0.1`，随机端口；`Info.plist` 的 ATS 例外已覆盖。
- 磁盘仍只有密文 + sidecar；明文仅在进程内回环 socket 上短暂存在。
- 日志只记 `kind`/HTTP 状态/会话 id，不记 URL 与 key（沿用 desktop_media 现有约束）。

## 5. 验证

**Host**
- 复用 fqapp `native/tests`（AES 向量、stream driver）与 `rust/testdata/cenc_sample_fixture.json`。
- `build.rs` 对 macOS 也编 C（仅测试用），跑 `cargo test`：Range 契约、seek、cancel、close 幂等。
- 新增单测：`mode=cached` 命中/未命中；无上游调用（用 mock transport 断言 0 请求）。

**构建**
- `./scripts/build_rust_ios.sh`；`nm -gU ios/Frameworks/libfqapi_core.a | grep sp_stream` 确认 C 符号已进静态库。
- `pod install` + `flutter build ios --release --no-codesign`。

**真机（iPhone 13 / iOS 27.2）**
- 首帧 P50/P90（对照 M0 的 1.1–1.5s，目标 <1s）。
- 冷缓存拖到 1/2、结尾、往回拖，画面不花屏；切集后旧会话释放（无重复 token/端口增长）。
- 弱网/断网：可理解的错误；`decrypt` 失败能静默回退 M0。
- 已缓存集断网播放（M1 新能力）；看完一集 `src/` 出现文件，重进秒开。
- 前后台、锁屏、全屏切换；20 分钟发热/耗电对比 M0。

**回归**
- `flutter test`（golden 不受影响）。
- 清空缓存后仍能走 M0 整集下载路径（回退验证）。

## 6. 任务拆分与估时

| # | 任务 | 估时 |
|---|---|---|
| T1 | 拷 native、改 `build.rs`/`Cargo.toml`/`lib.rs`，跑通 iOS 静态库（含 C 符号） | 0.5–1d |
| T2 | `desktop_media` 抽 `open/close` + FRB 接口 + 重新生成绑定 | 0.5d |
| T3 | `mode=cached` + Dart `media_session.dart` + 播放页接入/回退 | 0.5–1d |
| T4 | 写穿缓存 + 存储开关 + 错误映射文案 | 0.5d |
| T5 | 真机验证、调优与问题修复 | 1d |
| | **合计** | **2–4d** |

## 7. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| C 在 Apple 工具链编不过（C11 atomics/符号） | 阻塞 T1 | 失败即切方案 B；先在本机 `cc` 验证最小编译 |
| iOS 上 `reqwest::blocking` 体积/线程问题 | 包体、卡顿 | 只对 iOS target 开 feature；必要时改异步 reqwest（+0.5d） |
| AVPlayer 对回环 Range 行为差异 | seek 花屏/卡顿 | `/src` 已验证同类链路；逐档对比 200/206/416 |
| 会话泄漏（端口/线程） | 长时间使用后异常 | close 兜底 + 真机日志观察会话数 |
| 写穿缓存 2× 流量 + 128MB 预算 | 用户流量/磁盘 | 默认开但可关；预算调整放 M2 |
| 上游地址过期（403） | 播放中断 | 重新取流后重开会话（4.7） |

## 8. 后续（M2）：整剧缓存 / 下载管理

M1 之后另立需求，缓存格式不变、天然兼容：

- 预算可配：128MB（约 5–10 集）不够整剧，按「每剧预算 / 全局上限 / 仅 Wi-Fi」可配。
- 淘汰策略：全局 mtime 最旧淘汰会误删在追的剧 → series 分桶 + pinned 不被淘汰。
- 下载管理：队列/进度/暂停重试（`refresh=1` 复用）、按剧删除；内核已有 `Semaphore(2)`
  与 per-file 锁，可加串行队列与优先级。
- 会话内 tee 写穿（省掉 2× 流量），作为 4.5 的优化项。
- iOS 后台下载不可靠：整剧缓存主要靠前台/短时后台任务，不做「挂着下整部」的承诺。
- 预计 2–4 人天，可与 M1 并行。

## 9. 参考

- [video-playback.md](video-playback.md)：M0 决策、边界、真机验收记录
- [bookmall-tabs.md](bookmall-tabs.md)：短剧流 `tab_type` 对照
- `fqapp/rust/src/desktop_media.rs`、`fqapp/rust/src/desktop_fetch.rs`：Windows 已验证的流式会话实现（本仓库已拷入，待解 cfg）
- `fqapp/native/crypto_core/`、`fqapp/native/README.md`：CENC 流式解密库与已知限制（分片 MP4、CBC/pattern、多 KID 不支持）
- `fqapp/lib/services/desktop_media.dart`：Dart 侧 FFI 调用与会话生命周期参考
