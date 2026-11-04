# 视频播放：方案决策与待定问题

> 分支：`feat/lhy/video-playback`（从 `main` 切出）
> 状态：方案已定，实现未开始。本文只记录决策与待确认项，不含代码。
> 背景：参考同级 `fqapp`（Android ExoPlayer + Windows media_kit，iOS 未实现）补 iOS 视频播放能力。

## 1. 已定决策

### 1.1 产品形态

1. **新增一个视频 tab**，布局与现有小说一致：顶部搜索框 + 内容列表；点进**详情页**，点**集数**进入播放页。
2. **流式回环必做**：起播不依赖整集下载（R1）。
3. **同时支持"先缓存再播放"**：下载完成后可离线播放（R0 的 `/src` 加密缓存 + 按 Range 解密已经可用）。
4. **不做清晰度切换**：本轮不暴露清晰度入口；`variants` 仍在数据层保留，后续再开。
5. **不做弹幕**，播放优先保性能。

### 1.2 播放器与渲染

6. **播放器走 AVFoundation 系**，不自研完整 Swift 播放器、不引 `media_kit`。
   - 起始实现用 `video_player`（底层 AVPlayer）；**具体用官方插件还是薄 Swift 插件待 M0 实测后定**。
   - `media_kit` 排除原因：iOS 原生库 `media_kit_libs_ios_video` 停留在 1.1.4（2023 年、unlisted），libmpv/FFmpeg 二进制许可性质未核实，体积与维护风险都高于收益。
7. **渲染通路优先 platformView**：无弹幕叠加需求，`video_player` 的 `VideoViewType.platformView` 底层就是 `AVPlayerLayer`，避免逐帧纹理拷贝，性能和发热更好；M0 同时测 texture 做对比，若平台视图在全屏/转场有合成问题再退回 texture。

### 1.3 明确不做（本轮及可预见范围）

8. 画中画、HDR、后台播放、AirPlay、锁屏/控制中心媒体信息、远程控制、来电/耳机中断、弹幕、评论、分屏布局、投屏、清晰度切换、听书。
   - 后台：不配 `UIBackgroundModes: audio`，退后台按 `video_player` 默认行为**暂停**，但**保留播放器**（不释放、不关回环会话），回前台继续。
   - 音频：**独占播放，不混音**（不开 `mixWithOthers`）；开始播放时打断其他 App 的音频；项目后续不做听书。
9. **进度只记到"集"**，不记秒；重新进入从该集开头开始（后续若要秒级再改）。

### 1.4 工程约定

10. 本需求**必须破例**：要新增依赖（`video_player`），改 `pubspec.yaml` / `ios/` / `rust/`。实现前同步更新 `CONTRACTS.md` 的硬性规则与依赖白名单。
11. iOS 构建按 `fqapp` 的经验处理：Xcode 27 + CocoaPods 1.17，必要时继续关闭 Swift Package Manager；新增插件后需 `pod install` 并实测构建。
12. 编码兼容（h265 档、`moov` 前置/后置）在实现侧消化，不暴露用户可见选项；不可播的档位按已有 `variants` 回退逻辑降档。

## 2. 可复用的现成资产

| 资产 | 位置 | iOS 现状 |
|---|---|---|
| 视频取流接口（`/api/v1/videos/<id>`，`mode=stream` 出远程地址+key，默认整集下载） | `rust/src/endpoints/video.rs` | 已编进 iOS 静态库，可直接调 |
| CENC 解密 + Range 服务（`/src/<id>.mp4`，200/206/416，`video/mp4`） | `rust/src/endpoints/video.rs` `serve_src_file`、`rust/src/dispatch.rs` | **可用**，回环读路由不需要 capability token |
| 回环 HTTP adapter | `rust/src/server.rs`、`rust/src/api/mod.rs` | 随 `init` 无条件启动，`baseUrl()` 可取 |
| 流式解密回环（每会话独立端口 + token，Range→C 流解密） | `fqapp/rust/src/desktop_media.rs` | **未编进 iOS**（`build.rs` 只在 Windows 生效，novel-playlet 尚无 `native/`） |
| 播放器 UI / 集数据模型 | `fqapp/lib/pages/player_page.dart`、`episode_source_cache.dart` 等 | 可搬运，播放器 host 需按 AVFoundation 重写 |

## 3. 实施路径

- **M0（链路验证）**：Dart 补资源 URL 拼接 → 调 `/api/v1/videos/<id>`（非 stream）拿 `/src/<id>.mp4` → `video_player` 起播；同时验证 ATS、Range/seek、texture vs platformView 的首帧/发热对比。
- **M1（流式回环）**：把流式解密回环扩到 iOS，起播不再等整集下载。实现选型见 4.1。
- **M2（功能闭环）**：视频 tab（搜索 + 列表）+ 详情页 + 选集 + 播放页 + 缓存后离线播放。
- **M3**：待定（缓存清理、错误重试等按 4.2 后续再定）。

## 4. 待定问题

### 4.1 P0：真机条件恢复后必须验证

1. **ATS**：iOS 17 起 IP 地址不再默认放行，`NSExceptionDomains["127.0.0.1"]` 是否够、`NSAllowsLocalNetworking` 是否必需、iOS 15 最低版本下是否一致。
2. **AVPlayer 能否直接消费现有 `/src` 回环**：`video/mp4`、`Accept-Ranges`、206/416、无 `Origin`、`Host` 带端口均符合预期，但 AVPlayer 会并发/乱序/重复发小 Range，起播与拖动 seek 必须真机实测。
3. **流式回环的技术选型**（建议先做 C 流移植）：
   - 方案 A：把 `fqapp/rust/src/desktop_media.rs` 的 cfg 从 Windows 扩到 iOS，给 Apple 目标编 `native/crypto_core`（纯 C11），从 fqapp 拷入 `native/`；改动小、与 Windows 行为一致。
   - 方案 B：不引入 C，在现有 axum 回环上新开一条 `/media/<session>.mp4`，用纯 Rust `apply_cenc_index` + 远程 Range 抓取；无 C 依赖，但要重写 moov 拉取与远程 Range 缓存。
   - 决定依据：M0/M1 的构建成本与首播延迟实测。
4. **视频 tab 的命名与位置**：暂定样式与小说 tab 一致，具体名称/图标/是否放第二个 tab 待定。

### 4.2 P1：实现过程中定

5. **缓存与流式的关系**：进入播放默认流式，后台按需缓存（类似 fqapp 的"边看边缓存"）还是只做手动下载？下载目录/上限/清理策略后续细化。
6. **错误与重试**：CDN 4xx/过期地址、变体降档、重试上限、错误文案（是否对齐 fqapp 的 `PlaybackIssue` 四类）。
7. **起播位置**：进度只记到集，重新进入从 0 开始；若某集看了一半退出，下次是否仍从 0（当前决定：是）。
8. **详情页/选集页数据**：复用 Rust 已有的 `video_detail` / `pseries`（剧集列表）接口，还是需要新增字段；分页与失败态。
9. **首播延迟目标**：流式回环下首帧 P50/P90 目标值，作为是否要更大预读窗口的依据。

### 4.3 P2：收尾

10. 首帧/seek/发热基线：用真机 Instruments 记录（首帧 P50/P90、seek 出帧、20 分钟温升与掉电）。
11. 包体积增量（预计很小，需实测）。
12. 免费签名 7 天对验证节奏的影响（每 7 天重装；后台/重启场景单独排）。
13. 代码归属：播放器抽象、数据模型、页面放 `lib/features/video/` 还是新建 `lib/media/`。
14. 实现后同步 `README.md`（功能表/已知限制）与 `CONTRACTS.md`（依赖与平台规则）。

## 5. M0 验收清单

- [ ] iOS 真机 `video_player` 能起播 `http://127.0.0.1:<port>/src/<id>.mp4`（先确认不配 ATS 会失败，配好后成功）
- [ ] 起播收到首帧、时长、分辨率
- [ ] 拖到中间/末尾再回拖，画面正确、无花屏（验证 Range 解密）
- [ ] 切集后旧播放器释放、新集正常起播
- [ ] 退后台自动暂停，回前台可继续（播放器保留）
- [ ] 弱网/断网给出可理解错误文案，不卡死
- [ ] texture 与 platformView 两种渲染通路的首帧/CPU/发热对比记录

## 6. 参考

- `fqapp/IOS.md`：iOS 现状与"要补需接 media_kit 或 AVPlayer 插件"的说明
- `fqapp/rust/src/desktop_media.rs`：回环流式解密参考实现（Windows）
- `fqapp/lib/services/native_player.dart` / `episode_source_cache.dart`：播放器契约与数据模型参考

## 7. 决策记录

| 日期 | 结论 |
|---|---|
| 2026-11-04 | 新增视频 tab（搜索+列表 → 详情 → 选集 → 播放）；流式回环必做，同时支持缓存后播 |
| 2026-11-04 | 不做画中画/HDR/后台/AirPlay/锁屏/中断/弹幕/清晰度切换/听书；音频独占不混音；退后台暂停但保留播放器；进度只记到集 |
| 2026-11-04 | 播放器走 AVFoundation 系（先 `video_player`），渲染优先 platformView；拒绝 media_kit |
