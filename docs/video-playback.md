# 视频播放：方案决策与待定问题

> 分支：`feat/lhy/video-playback`（从 `main` 切出）
> 状态：M0 骨架已实现并真机验证（短剧 tab / 短剧详情 / 播放页），待补流式起播。
> 本文只记录决策与待确认项，不含代码。
> 背景：参考同级 `fqapp`（Android ExoPlayer + Windows media_kit，iOS 未实现）补 iOS 视频播放能力。

## 1. 已定决策

### 1.1 产品形态

1. **新增一个短剧 tab**（底部导航文案「短剧」），布局与现有小说 tab 一致：顶部搜索框 + 内容列表；点进**详情页**，点**集数**进入播放页。
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
   - 后台：不配 `UIBackgroundModes: audio`，也**没有**做显式后台暂停。实测（2026-11-04，iPhone 13）：快速切后台再回来，播放仍在继续（系统还没挂起进程）；长时间后台会被系统挂起、播放停止。若以后要"退后台立刻暂停"，需要 `WidgetsBindingObserver`；本轮按现状不处理（产品确认可接受）。
   - 音频：**独占播放，不混音**（不开 `mixWithOthers`）；开始播放时打断其他 App 的音频；项目后续不做听书。
9. **进度只记到"集"**，不记秒；重新进入从该集开头开始（后续若要秒级再改）。

### 1.4 工程约定

10. 本需求**必须破例**：要新增依赖（`video_player`），改 `pubspec.yaml` / `ios/` / `rust/`。实现前同步更新 `CONTRACTS.md` 的硬性规则与依赖白名单。
11. iOS 构建按 `fqapp` 的经验处理：Xcode 27 + CocoaPods 1.17，必要时继续关闭 Swift Package Manager；新增插件后需 `pod install` 并实测构建。
12. 编码兼容（h265 档、`moov` 前置/后置）在实现侧消化，不暴露用户可见选项；不可播的档位按已有 `variants` 回退逻辑降档。

### 1.5 屏幕方向策略（2026-11-04 定）

- **App 全局锁竖屏**（`main.dart` 启动时 `SystemChrome.setPreferredOrientations([portraitUp])`）：阅读器是横向分页、列表也是竖排布局，转横屏只会挤坏布局。
- **只有播放页、且只有横屏视频**（`controller.value.aspectRatio > 1.05`）才显示「全屏」按钮；点了才 `setPreferredOrientations([landscapeLeft, landscapeRight])` 进横屏，同时用 `SystemUiMode.manual + overlays: []` 隐藏状态栏（iOS 上 leanBack/immersive 无效）。
- **退出路径都要恢复竖屏**：退出全屏、系统返回手势（全屏时先退全屏，`PopScope` 拦一层）、离开播放页（`dispose`）、以及全屏中切到竖屏视频（自动退全屏）。
- **全屏时视频铺满整屏**：播放层不吃 SafeArea（横屏底部 Home 指示条那一条也盖住，避免画面下方黑边），只有顶部/底部控制条各自套 SafeArea 避让；16:9 视频在 19.5:9 横屏上左右留黑边是正常的（保持完整画面，不裁切）。
- 竖屏视频没有全屏入口：竖屏内容全屏只会更小。

## 2. 可复用的现成资产

| 资产 | 位置 | iOS 现状 |
|---|---|---|
| 视频取流接口（`/api/v1/videos/<id>`，`mode=stream` 出远程地址+key，默认整集下载） | `rust/src/endpoints/video.rs` | 已编进 iOS 静态库，可直接调 |
| CENC 解密 + Range 服务（`/src/<id>.mp4`，200/206/416，`video/mp4`） | `rust/src/endpoints/video.rs` `serve_src_file`、`rust/src/dispatch.rs` | **可用**，回环读路由不需要 capability token |
| 回环 HTTP adapter | `rust/src/server.rs`、`rust/src/api/mod.rs` | 随 `init` 无条件启动，`baseUrl()` 可取 |
| 流式解密回环（每会话独立端口 + token，Range→C 流解密） | `fqapp/rust/src/desktop_media.rs` | **未编进 iOS**（`build.rs` 只在 Windows 生效，novel-playlet 尚无 `native/`） |
| 播放器 UI / 集数据模型 | `fqapp/lib/pages/player_page.dart`、`episode_source_cache.dart` 等 | 可搬运，播放器 host 需按 AVFoundation 重写 |

## 3. 实施路径

- **M0（已实现，2026-11-04 真机验证通过）**：短剧 tab（搜索 + 短剧推荐流）、短剧详情页（简介 + 选集）、播放页（`video_player`，播放/暂停/拖动/上下集/播完自动下一集）；取流走非 stream 模式，播放内核 `/src/<id>.mp4` 的按 Range 解密结果；`ios/Runner/Info.plist` 已加 127.0.0.1 的 ATS 例外。
- **M1（未开始）**：把流式解密回环保留到 iOS，起播不再等整集下载。实现选型见 4.1。
- **M2（部分完成）**：短剧 tab / 详情 / 选集 / 播放页已闭环；缓存后离线播放复用 `/src` 缓存，暂未做缓存管理 UI。
- **M3**：待定（缓存清理、错误重试等按 4.2 后续再定）。

## 4. 待定问题

### 4.1 P0：真机条件恢复后必须验证

1. ~~**ATS**~~ **已验证（2026-11-04）**：`NSExceptionDomains["127.0.0.1"]` + `NSAllowsLocalNetworking` 在 iOS 27.2 上放行，AVPlayer 正常起播回环地址。
2. ~~**AVPlayer 消费 `/src` 回环**~~ **已验证（2026-11-04）**：起播成功、拖动 seek 出画面，首页验证 206/416 行为正常（host 侧另测 `bytes=0-31`→206、越界→416、`Content-Type: video/mp4`、首 16 字节为 `ftyp isom`）。
3. **流式回环的技术选型**（建议先做 C 流移植）：
   - 方案 A：把 `fqapp/rust/src/desktop_media.rs` 的 cfg 从 Windows 扩到 iOS，给 Apple 目标编 `native/crypto_core`（纯 C11），从 fqapp 拷入 `native/`；改动小、与 Windows 行为一致。
   - 方案 B：不引入 C，在现有 axum 回环上新开一条 `/media/<session>.mp4`，用纯 Rust `apply_cenc_index` + 远程 Range 抓取；无 C 依赖，但要重写 moov 拉取与远程 Range 缓存。
   - 决定依据：M0/M1 的构建成本与首播延迟实测。
4. ~~**渲染通路**~~ **已验证（2026-11-04）**：`VideoViewType.platformView` 在真机上顶部/底部 Flutter 控制条**没有被原生视频层遮挡**，保留 platformView；未做 texture 对比（无遮挡迹象，按方案 A 处理）。
5. ~~**视频 tab 数据源过窄**~~ **已解决（2026-11-04）**：书城首页接口按 `tab_type` 分媒介，取值对齐官方 `BookstoreTabType`（fqapp `lib/models/channel_tab.dart` 有抄录）：2 推荐/小说、5 听书、**8 短剧（看剧）**、9 漫画、16 视频 feed、24 漫剧、25 小说、103 短篇。短剧 tab 已从 16（视频 feed，只回 2 部且无游标）换成 **8**：实测 6 部/页，`next_offset` 逐页 +1（offset 0→1→2 每页都是新剧），session 稳定；响应还要按 `tab_type` 认领（对不上说明上游答了别的分类，整页拒绝）。
   - 后续可扩展：漫剧（24，实测 12 部但 offset>0 空，只能首页）、听书（5）、漫画（9，fqapp 走搜索兜底）。
   - 翻页兜底：fqapp 在推荐游标耗尽后回退到同分类搜索流；本项目暂未做（游标翻完就显示「没有更多了」）。

### 4.2 P1：实现过程中定

5. **缓存与流式的关系**：进入播放默认流式，后台按需缓存（类似 fqapp 的"边看边缓存"）还是只做手动下载？下载目录/上限/清理策略后续细化。
6. **错误与重试**：CDN 4xx/过期地址、变体降档、重试上限、错误文案（是否对齐 fqapp 的 `PlaybackIssue` 四类）。
   - 现状（2026-11-04）：播放页已把失败分类展示（取流超时 / 取流失败 / 本地回环中断 / 解码失败 / ATS 拦截 / 4xx）+ 原始错误可复制；内核支持 `refresh=1` 强制重新下载，UI 有「重新下载这一集」。仍未做自动重试与变体降档重试。
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

- [x] iOS 真机 `video_player` 能起播 `http://127.0.0.1:<port>/src/<id>.mp4`（2026-11-04，iPhone 13/iOS 27.2）
- [x] 起播收到首帧、时长（02:28）、画面比例 16:9
- [ ] 拖到中间/末尾再回拖，画面正确、无花屏（验证 Range 解密）——已实现"拖动只更新 UI，松手才 seek"，待真机回归
- [ ] 切集后旧播放器释放、新集正常起播
- [x] 退后台行为已实测：**不会**自动暂停（快速切后台回来仍在播），产品确认可接受；长时间后台由系统挂起停止
- [ ] 弱网/断网给出可理解错误文案，不卡死
- [ ] 横屏视频出现「全屏」按钮，点了转横屏并隐藏状态栏；退出全屏/返回/离开播放页都恢复竖屏；全局其它页面任何方向都不转横屏（2026-11-04 已实现，待真机回归）
- [x] platformView 渲染通路：Flutter 控制条未被原生层遮挡（texture 对比未做，无遮挡迹象）
- [ ] 播放中控制条 3.5s 自动隐藏、点画面切换；暂停时保持常显（2026-11-04 已实现，待真机回归）
- [ ] seek/弱网时显示缓冲小 spinner（2026-11-04 已实现，待真机回归）

### 5.1 M0 真机验证记录（2026-11-04）

设备：iPhone 13（`00008110-001431393AC2801E`，iOS 27.2），包：`com.lihangyu.novelPlaylet 0.6.0+14`（免费签名，重签后安装）。

| 项 | 结果 |
|---|---|
| 起播 | ✅ 出画面、有声音，ATS 回环放行 |
| 起播耗时 | ✅ 约 1.1~1.5s（先整集下载后播；单集 2:28，内核缓存已就绪） |
| 控制条遮挡 | ✅ platformView 无遮挡 |
| 时长/进度 | ✅ 02:28 / 00:03，暂停按钮状态正确 |
| 后台 | ⚠️ 不暂停（可接受） |
| 短剧 tab 内容 | ✅ 已切 `tab_type=8`（6 部/页、游标可翻页，见 4.1-5） |

## 6. 参考

- `docs/bookmall-tabs.md`：书城首页流 `tab_type` 分类对照（小说/短剧/漫剧/漫画/听书…），本轮短剧流选型的依据
- `fqapp/IOS.md`：iOS 现状与"要补需接 media_kit 或 AVPlayer 插件"的说明
- `fqapp/rust/src/desktop_media.rs`：回环流式解密参考实现（Windows）
- `fqapp/lib/services/native_player.dart` / `episode_source_cache.dart`：播放器契约与数据模型参考

## 7. 决策记录

| 日期 | 结论 |
|---|---|
| 2026-11-04 | 新增视频 tab（搜索+列表 → 详情 → 选集 → 播放）；流式回环必做，同时支持缓存后播 |
| 2026-11-04 | 不做画中画/HDR/后台/AirPlay/锁屏/中断/弹幕/清晰度切换/听书；音频独占不混音；退后台暂停但保留播放器；进度只记到集 |
| 2026-11-04 | 播放器走 AVFoundation 系（先 `video_player`），渲染优先 platformView；拒绝 media_kit |
| 2026-11-04 | M0 真机验证通过：ATS 回环放行、platformView 无遮挡、起播 ~1s；后台不做显式暂停（产品确认可接受）；播放器补控制条自动隐藏/点按显隐、缓冲 spinner、拖动松手才 seek |
| 2026-11-04 | 短剧流改用 `tab_type=8`（官方 video_episode，fqapp 短剧 tab 同款）：6 部/页、游标翻页；16 是视频 feed（2 部无游标），不再使用；响应按 `tab_type` 认领，答非所问整页拒绝 |
| 2026-11-04 | UI 重构：列表抽 `app/feed/`（FeedState/FeedView/FeedGrid/SearchField/Footer），详情抽 `app/widgets/detail/`（DetailCoverHeader/DetailIntroCard/标签/区块标题）；短剧详情改成与小说详情同版式（沉浸渐变+封面头+简介卡），选集作为特殊模块保留；播放页加「选集」弹层（6 列数字、当前集高亮）；两个推荐页保留下拉刷新（搜索框固定、内容区下滑松手刷新）；其它页面去掉下拉刷新，全局改为 clamping 物理（无橡皮筋） |
| 2026-11-04 | 播放失败可定位：错误页显示「标题 + 可能原因 + 可复制技术详情（集 id/播放地址/原始异常/堆栈前 4 行）」，按钮为重试 / 重新下载这一集 / 复制错误信息；内核取流支持 `refresh=1`（删缓存 + side key 后重新下载），解决"坏缓存导致重试永远失败" |
| 2026-11-04 | 修复翻页请求风暴：`withLoadMoreError` 会把 `loadingMore` 重置导致并发守卫失效，同一 offset 每帧连发（实测 12 秒 220 次），并发响应互相覆盖造成列表闪烁；两个 `with*` 互保字段 + 控制器重入锁 + 用最新状态追加；回归见 `test/feed_concurrency_test.dart` |
| 2026-11-04 | UI 细节：封面比例统一走 `kCoverAspect`（11:8）——小说 240×320 与短剧 400×571 原生比例不同，此前各写 1.38 / 4/3，切 tab 短剧封面矮 5pt；现在两条推荐流、搜索结果、书架、最近阅读、详情封面同宽同高。两个 tab 的搜索态统一成横向列表（新增 `app/feed/feed_results.dart`：`FeedResultsSliver` + `FeedResultTile`，封面 64×88），条数文案统一「已加载 / 共 N 本·部」，短剧卡圆角对齐 `AppTheme.cardRadius`；回归见 `test/ui_preview_test.dart` 的封面尺寸断言 |
| 2026-11-04 | 方向：App 全局锁竖屏；只有播放页的横屏视频（宽高比 >1.05）给「全屏」按钮，点击才临时开横屏，退出全屏/返回/离开播放页/切到竖屏视频都恢复竖屏 |
