# novel-playlet

小说 / 短剧 App：**先做 iOS**。复用同仓库族 `fqapp` 的 Rust 内核（签名 / 设备注册 / 正文解密 / 上游接口），Flutter 侧重写 UI。

当前版本 `0.6.0+14`，已在 iPhone 13 / iOS 27.2 真机验证（免费 Apple ID 自签，7 天重签一次）。

> 内容实时来自第三方公开接口，App 不存任何内容。仅供学习研究，版权归原作者所有；使用后果自负。
>
> 本项目复用了 `fqapp` 的 Rust 内核与数据解析逻辑（GPL-3.0），因此整体按 **GPL-3.0** 发布，见 [LICENSE](LICENSE)。

## 现在能做什么

三个 tab：**小说** / **短剧** / **我的**（`IndexedStack`，切 tab 不丢滚动位置与已加载数据）

| 页面 | 状态 |
|---|---|
| 小说页：搜索框 + 三列推荐流（`tab_type=2`，下拉刷新、滚动分页、首屏不足自动补页）+ 搜索结果为横向列表 | ✅ |
| 短剧页：同一套骨架，推荐流走 `tab_type=8`（6 部/页、游标翻页），搜索走 `tab_type=11` | ✅ |
| 小说详情页：封面头/书名/作者/分类·状态·字数/评分、简介折叠、标签、目录（前 10 章 + 全部弹层）、底部「开始/继续阅读 + 加入书架」 | ✅ |
| 短剧详情页：同一套封面头/简介卡（分类 · 播放量、全 N 集），目录换成选集网格，点集直接进播放页 | ✅ |
| 阅读页：TextPainter 真实分页、左右翻页、点击分区、工具栏、字号/行距/4 种底色、目录跳章、邻章预取、正文本地缓存（300 章上限、7 天后后台刷新）、章节 + 页首段落进度保存 | ✅ |
| 播放页：`video_player`（AVPlayer）播放，控制条 3.5s 自动隐藏、缓冲 spinner、拖动松手才 seek、上下集/播完自动下一集、选集弹层、横屏视频全屏；密文交给内核 `/src` 按 Range 解密；失败给「原因 + 可复制详情 + 重新下载这一集」 | ✅ 骨架（先整集缓存后播） |
| 我的页：书架（长按管理）、最近阅读 3 条（带段落级续读）、存储占用与清理 | ✅ |
| 流式起播（边下边播）、整本离线下载、听书、漫画、评论、段评、登录、设置页 | ⬜ 后续 |

> 视频方案与边界见 [docs/video-playback.md](docs/video-playback.md)：本轮不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕。
>
> M1 流式起播（边下边播）的技术方案见 [docs/streaming-media-m1.md](docs/streaming-media-m1.md)。
>
> 书城首页流按 `tab_type` 分类的实测对照见 [docs/bookmall-tabs.md](docs/bookmall-tabs.md)；小说离线缓存方案（未实现）在 `feat/lhy/novel-cache` 分支的 `docs/novel-cache.md`。

## 架构

```
UI (features/*)  ──►  Riverpod controller  ──►  ApiClient (data/api)
                                                    │
                                                    ▼
                                    BackendTransport (core/backend)
                                     │ flutter_rust_bridge（进程内 FFI）
                                     ▼
                     Rust 内核 libfqapi_core（签名/设备池/请求/解密）
                                     │ HTTPS
                                     ▼
                                   上游接口
```

- **签名、设备池、重试、限流、正文解密全部在 Rust 侧**，Dart 只传 `(request_id, method, path, query, body, timeout_ms)`，对应 `rust/src/api/mod.rs` 暴露的 9 个函数：`init` / `request` / `cancel` / `shutdown` / `status` / `base_url` / `session_capability` / `set_device_pool_key` / `version`。
- 启动链：`main.dart`（锁竖屏、裁封面缓存）→ `BootstrapGate`（Splash，失败展示可读原因 + 重试）→ `BackendService.start()` → 内核 `init`。
- 内核随 `init` 起一个 loopback HTTP adapter（`rust/src/server.rs`，默认端口 18931），给播放器提供 `/src/<video_id><ext>`（ext 由上游地址推断，按 Range 解密；capability 只约束会改设备状态的写接口，读接口不校验）。
- 上游返回的是**原始 JSON**（Rust 只做正文解密），字段兼容集中在 `lib/data/models/`，列表/搜索的信封与游标解析在 `lib/data/api/api_client.dart`，页面只消费模型。
- 视频同样由内核解密：`/api/v1/videos/{id}` 把整集下载进本地缓存（CENC 源保留密文 + key sidecar，播放时按 Range 解密），返回上面的 `/src/...` 地址，播放器只拉明文 HTTP。
- 本地状态只有书架/阅读进度/最近阅读/阅读设置（`shared_preferences`），设备池密钥在 Keychain（`flutter_secure_storage`），池文件在 App 私有目录（加密）。

### 目录

```
lib/
  main.dart       入口：锁竖屏、启动前裁剪封面缓存、ProviderScope
  app/            MaterialApp（主题 / 中文本地化 / 路由）、启动闸门、三 tab 外壳
  app/feed/       列表页通用骨架（FeedState/FeedView：分页、补屏、下拉刷新、底部状态；FeedResultsSliver：搜索结果横向列表）
  app/theme/      Material 3 明暗主题（seed 天蓝）、统一滚动行为
  app/widgets/    共享组件（NovelCover 用 kCoverAspect 11:8、NovelGridCard、Loading/Error/Empty）
  app/widgets/detail/  详情页共用组件（封面头/简介卡/标签/区块标题）
  core/backend/   FRB 传输、内核启动与运行时文件部署
  core/cache/     封面图磁盘缓存、缓存占用统计与清理
  core/storage/   书架与进度存储、设备池密钥
  data/           接口客户端 + 模型与解析（含 video_series / video_detail / video_source）
  features/       recommend / video / detail / reader / mine（章节缓存在 reader/reader_chapter_cache.dart）
  src/rust/       flutter_rust_bridge 生成绑定（勿手改）
rust/             Rust 内核（从 fqapp 整体拷入）
assets/config/    config.json / filter.json / device_pool.example.json
docs/             视频播放方案、书城 tab_type 对照
scripts/          build_rust_ios.sh
test/             6 个测试文件 + goldens/（9 张）
CONTRACTS.md      页面开发约定（页面清单/数据层 API 已滞后，待同步）
```

## 构建与运行

环境（本机验证用，仓库未锁定工具链）：Flutter 3.47.9、Rust 1.99.0（`rustup target add aarch64-apple-ios`）、Xcode 27.2、CocoaPods 1.17；Dart SDK `^3.13.7`，iOS 部署目标 15.0。

```bash
flutter pub get   # flutter_rust_bridge 两端必须同为 2.13.0（pubspec / rust/Cargo.toml）

# 1) 编 Rust 内核静态库 → ios/Frameworks/libfqapi_core.a
./scripts/build_rust_ios.sh              # 只编真机 arm64（出 IPA 用）
./scripts/build_rust_ios.sh --simulator  # 需要模拟器时额外编两片模拟器目标并打 xcframework
pod install                              # 新增/更新插件后

# 2) 出未签名 App
flutter build ios --release --no-codesign   # 产物：build/ios/iphoneos/Runner.app

# 3) 打成未签名 IPA（ios-sideload 需要 Payload/ 结构）
cd build/ios && rm -rf Payload novel_playlet_unsigned.ipa \
  && mkdir Payload && cp -R iphoneos/Runner.app Payload/ \
  && zip -qry novel_playlet_unsigned.ipa Payload
```

Bundle ID `com.lihangyu.novelPlaylet`，显示名「小说铺」。Rust 静态库靠 `ios/Flutter/Release.xcconfig` 的 `-force_load` + `DEAD_CODE_STRIPPING=NO` 链进主二进制，`Info.plist` 已为 `127.0.0.1` 开 ATS 例外（视频回环）。

真机安装（免费 Apple ID 自签，7 天有效；复用本机已有工具）：

```bash
cd ~/workspace/ios-sideload
BUNDLE_ID=com.lihangyu.novelPlaylet IPA=/Users/lihangyu/workspace/novel-playlet/build/ios/novel_playlet_unsigned.ipa ./all.sh --mint
```

> 本机没有安装 iOS 模拟器 runtime，所以开发验证走「host 测试 + golden 截图 + 真机」。

## 测试

```bash
flutter test                       # 数据解析 + 缓存 + 并发回归 + UI golden 预览（不需要网络/内核/模拟器）
flutter test --update-goldens      # 重新生成 test/goldens/*.png（当前 9 张）
cargo build --manifest-path rust/Cargo.toml   # live probe 需要 host dylib
LIVE_PROBE=1 flutter test test/live_probe_test.dart   # 打真实上游，抓推荐/详情/目录/正文原始 JSON
```

- `test/parsers_test.dart`：字段类型不稳定（数值是字符串、列表是单对象、id 截断）的兼容逻辑。
- `test/video_parsers_test.dart`：短剧卡片/详情/取流的字段兼容与去重。
- `test/feed_concurrency_test.dart`：翻页请求必须串行（真机曾出现同一 offset 每帧连发、并发响应互相覆盖导致列表闪烁），同时锁住状态 copy 不丢字段。
- `test/cache_test.dart`：缓存统计/清理只动可重建缓存，书架、进度与设备池不动。
- `test/ui_preview_test.dart`：假 transport 注入固定数据，真实渲染各页面成 PNG（`test/goldens/`，9 张），并断言两条推荐流/搜索结果的封面尺寸与比例一致、搜索框不因清空按钮被撑高、带 `blockIndex` 进入阅读页不落在第一页。
- `test/live_probe_test.dart`：默认跳过；需要先 `cargo build` 出 host dylib，且网络能访问设备注册域名。

> golden 依赖 macOS 系统字体（Arial Unicode / STHeiti），换机器或换系统版本可能不一致。

## 本地数据与缓存

App 沙盒里会落盘的东西（iPhone 13 调试期实测：文稿与数据 400 MB，其中视频缓存 339 MB）：

| 位置（相对 App 沙盒） | 内容 | 上限 / 清理 |
|---|---|---|
| `Application Support/backend/src/` | 播放时下载的剧集（CENC 源保留密文 + 密钥 sidecar，非加密源则明文）、漫画图 | 内核 `MAX_VIDEO_CACHE_BYTES` = **128 MB**（视频与漫画图共用），下载完异步按最旧淘汰，同时最多 2 个下载；单集下载上限 2 GiB |
| `Library/Caches/libCachedImageData/` + `Application Support/libCachedImageData.db` | 封面图磁盘缓存（500–800px 大图也会落到这里）与 sqflite 索引 | 120 个对象 / 7 天；启动时体积 >40 MB 裁到 25 MB |
| `Application Support/reader_chapters/` | 章节正文 JSON（内存再叠 8 章 LRU） | 最多 300 个文件，超出按最旧淘汰；超过 7 天只算过期，仍先展示并后台刷新 |
| `Documents/diag.log` | 早期调试探针遗留日志（当前代码不再写入） | 清理时一并删除 |
| `Application Support/backend/config/` | 上游设备注册池、过滤配置 | **不是缓存**：删了要重新注册设备 |
| `Library/Preferences/*.plist` | 书架、阅读进度（含页首段落下标）、最近阅读、阅读设置 | **用户数据**：不清理 |

「我的 → 存储」会显示当前缓存占用（视频/封面/章节明细）并提供「清理」：只清上面四类可重建缓存，书架与进度不动。统计/清理逻辑在 `lib/core/cache/app_cache.dart`。

清理后 App 自身缓存≈0；某次真机观察沙盒里还剩 ~20 MB，是 iOS 自己生成的启动快照（`Library/SplashBoard`）与 Metal 着色器缓存，不归本 App 管理，重装/系统回收时会自动消化。

## 已知限制

1. **首次打开必须联网完成设备注册**（`log.snssdk.com`）。若本机代理/网络拦截该域名，会一直停在「阅读环境启动失败」，可点重试。
2. 没有整本离线下载：正文只有本地章节缓存（最多 300 个文件；7 天后视为过期但不清除，仍先展示再后台刷新），视频缓存也只是「播放时下载」的缓存（上限 128 MB），不能当离线片库；离线缓存的 M0 方案见 `feat/lhy/novel-cache` 分支的文档。
3. 无评论/段评/听书/漫画；阅读器只有横向分页，没有滚动跨章。
4. 阅读进度记录到「章 + 页首段落下标」：换字号/换设备重新分页后能回到读到的那一段，但没有精确到页（页号本身随字号变化）。
5. 视频是骨架：起播要等整集下载进内核缓存（流式回环见 [docs/video-playback.md](docs/video-playback.md) M1）；不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕；视频进度只记到「集」、不落盘。退后台不会主动暂停（快速切回继续播，长时间后台由系统挂起）。短剧流走书城首页的 `tab_type=8`（6 部/页、`next_offset` 游标翻页），翻完游标后暂时不会像 fqapp 那样回退到搜索兜底，见 [docs/video-playback.md](docs/video-playback.md) 4.1-5。
6. App 全局锁竖屏（阅读器是横向分页、列表也是竖屏布局）；只有播放页的横屏视频才给「全屏」按钮，退出全屏/返回/离开播放页都会恢复竖屏。
7. iOS 上架需处理 GPLv3 与内容授权，不建议按上架排期；当前定位自用/自签。

## 后续扩展点

- **加 tab**：`lib/app/shell/home_shell.dart` 的 `_destinations` / `_pages` 各加一项，页面走 `ConsumerWidget`。
- **加页面**：`lib/app/router.dart` 加一条 `AppRoutes`。
- **Android**：内核已是 `cdylib`，需补 `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/libfqapi_core.so`（参照 fqapp 的 `scripts/build_rust_backend.sh`），NDK 与 ABI 的坑见 fqapp `DEVELOPMENT.md`；Flutter 侧代码无需改动。
