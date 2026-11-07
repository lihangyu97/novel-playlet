# novel-playlet

小说 / 短剧 App：**先做 iOS**。复用同仓库族 `fqapp` 的 Rust 内核（签名 / 设备注册 / 正文解密 / 上游接口），Flutter 侧重写 UI。

当前版本 `0.6.0+14`，已在 iPhone 13 / iOS 27.2 真机验证（免费 Apple ID 自签，7 天重签一次）。

> 内容实时来自第三方公开接口，App 不存任何内容。仅供学习研究，版权归原作者所有；使用后果自负。
>
> 本项目复用了 `fqapp` 的 Rust 内核与数据解析逻辑（GPL-3.0），因此整体按 **GPL-3.0** 发布，见 [LICENSE](LICENSE)。

## 现在能做什么

两个 tab：**推荐** / **我的**（`PageView` + keep-alive，切 tab 不丢滚动位置与已加载数据；底部是悬浮胶囊底栏，基于 Flutter `NavigationBar` 改造，参考同仓库族 PiliPlus 的 `FloatingNavigationBar`，见 `lib/app/shell/floating_navigation_bar.dart`；`extendBody` 让列表从胶囊下方穿过，各滚动页末尾按底栏高度留白；点底栏时两个页面横向滑动切换（`PageView` + keep-alive，保留滚动位置与已加载数据））。推荐页搜索框下方是可左右滑动的分类 tabs：**小说**（`tab_type=2`）/ **短剧**（8）/ **漫剧**（24），三个分类各自保留列表与滚动位置，内容区也能左右滑动切换。

| 页面 | 状态 |
|---|---|
| 推荐页：搜索框 + 分类 tabs（小说/短剧/漫剧）+ 各分类三列推荐流（下拉刷新、滚动分页、首屏不足自动补页）+ 搜索结果为横向列表；搜索框 40pt 高、继续往下浏览时整条收起（分类 tabs 吸顶）、往回滚的第一下就展开（不必滚回顶部）、收起后切分类保持收起；小说 `tab_type=2`、短剧 `8`（6 部/页、游标翻页）、漫剧 `24`（首页一屏无游标，滑到底走搜索兜底翻页） | ✅ |
| 小说详情页：封面直接作为顶部背景（Hero 从列表飞入后落成背景，顶部不透明、向下渐隐到透明，高度固定不随内容跳动）、书名/作者/评分、简介折叠、标签、目录（前 10 章 + 全部弹层）、底部「开始/继续阅读 + 加入书架」；文字信息等接口就绪后从下方淡入（`lib/app/widgets/cover_hero.dart` / `lib/app/widgets/detail/detail_common.dart`） | ✅ |
| 短剧详情页：同一套封面背景/简介卡（全 N 集、播放量），选集默认展开、36 集自动分一个 tab、一行 6 个、只显示集数（1000+ 集也不撑爆页面），点集直接进播放页；列表封面同样 Hero 飞入并直接落成背景，正文内容等接口就绪后淡入 | ✅ |
| 阅读页：TextPainter 真实分页、左右翻页、点击分区、工具栏、字号/行距/4 种底色、目录跳章、邻章预取、正文本地缓存（300 章上限、7 天后后台刷新）、章节 + 页首段落进度保存 | ✅ |
| 播放页：`video_player`（AVPlayer）播放，控制条 3.5s 自动隐藏、缓冲 spinner、拖动松手才 seek、上下集/播完自动下一集、选集弹层、横屏视频全屏；密文交给内核 `/src` 按 Range 解密；失败给「原因 + 可复制详情 + 重新下载这一集」 | ✅ 骨架（先整集缓存后播） |
| 我的页：**小说 / 短剧** 两块镜像面板——右下角悬浮按钮或左右滑动切换；切换时按「最近阅读/观看 → 标题 → 书架/收藏」三块依次延迟 0/100/200ms 滑出滑入（每块滑 300ms，最近块先走、标题第二拍）；设置入口合并成一个按钮，随面板在屏幕内左右滑动、不会滑出屏幕。小说侧含书架（长按管理）+ 最近阅读 3 条（带段落级续读）；短剧侧含收藏网格（长按管理、点进详情）+ 最近观看 3 条（和最近阅读同一版式：封面在左、箭头在右，点击直接续播对应集） | ✅ |
| 设置页：主题色（8 个预设 + HSV 自定义取色，全站即时生效并持久化）、存储占用（视频/封面/章节明细）与清理；离线缓存不在这里管理，页内提示去「我的 → 缓存」 | ✅ |
| 离线缓存：小说整本 / 短剧整剧一键下载到独立 pinned 区（小说上限 1 GB、短剧 3 GB），断网可读可看；与自动缓存物理隔离，只能在「我的 → 缓存」页删除/清空（M3 确认框）；已缓存的短剧切换秒开。详情底栏「缓存/缓存中/已缓存」三态，缓存中/已缓存点进「我的」右下角悬浮入口的缓存中心看进度/网速（Hero 点回详情）；同时只跑一个任务，其余 FIFO 排队（最多 20 个，完成/失败/取消后自动开始下一个） | ✅ |
| 流式起播（边下边播）、听书、漫画、评论、段评、登录 | ⬜ 后续 |

> 视频方案与边界见 [docs/video-playback.md](docs/video-playback.md)：本轮不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕。
>
> 书城首页流按 `tab_type` 分类的实测对照见 [docs/bookmall-tabs.md](docs/bookmall-tabs.md)；离线缓存（离线小说/短剧）的方案、存储布局与验收清单见 [docs/offline-cache.md](docs/offline-cache.md)。

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
- 内核随 `init` 起一个 loopback HTTP adapter（`rust/src/server.rs`，默认端口 18931），给播放器提供 `/src/<video_id><ext>`（ext 由上游地址推断，按 Range 解密）。免鉴权的只有 App 自己用的 7 个读接口、`/src/*` 和 `/health`；其余 fqapp/Legado 兼容路由（听书、漫画、评论、排行榜……）必须带本次启动的 capability，会以设备身份写数据的接口（评论/点赞/回复）同样要 capability。
- 上游返回的是**原始 JSON**（Rust 只做正文解密）：卡片解析统一在 `lib/data/parsers/`（`card_walker` 的递归遍历 + 小说/短剧两个 adapter），`lib/data/models/` 只留字段模型；列表/搜索的信封与游标解析在 `lib/data/api/api_client.dart`，页面只消费模型。
- 视频同样由内核解密：`/api/v1/videos/{id}` 把整集下载进本地缓存（CENC 源保留密文 + key sidecar，播放时按 Range 解密），返回上面的 `/src/...` 地址，播放器只拉明文 HTTP。
- 本地状态只有书架/阅读进度/短剧收藏/观看进度/最近阅读/阅读设置/主题色（`shared_preferences`），设备池密钥在 Keychain（`flutter_secure_storage`），池文件在 App 私有目录（加密）。

### 目录

```
lib/
  main.dart       入口：锁竖屏、启动前裁剪封面缓存、ProviderScope
  app/            MaterialApp（主题 / 中文本地化 / 路由）、启动闸门、底部 tab 外壳
  app/theme/      Material 3 明暗主题（seed 可自定义、默认天蓝）、主题色偏好、统一滚动行为
  app/widgets/    共享组件（NovelCover 用 kCoverAspect 11:8、MediaCard 列表卡骨架、Loading/Error/Empty）
  app/widgets/detail/  详情页共用组件（封面头/简介卡/标签/区块标题）
  core/backend/   FRB 传输、内核启动与运行时文件部署
  core/cache/     封面图磁盘缓存、缓存占用统计与清理
  core/storage/   书架与进度存储、设备池密钥；offline/ 是离线缓存（小说/短剧两个 pinned 区）
  data/           接口客户端 + 模型；parsers/ 是卡片解析（card_walker / novel_parsers / video_parsers）
  features/       recommend / feed / video / detail / reader / mine / settings / cache（离线下载器 + 缓存中心）
  features/feed/  列表页通用骨架（FeedState/FeedView：分页、补屏、下拉刷新、底部状态；FeedResultsSliver：搜索结果横向列表）
  src/rust/       flutter_rust_bridge 生成绑定（勿手改）
rust/             Rust 内核（从 fqapp 整体拷入；fork 基线与本地补丁见 PATCHES.md）
assets/config/    config.json / device_pool.example.json（启动时部署到 App 沙盒）
docs/             视频播放方案、书城 tab_type 对照、阅读页分页真机 profile、离线缓存方案
scripts/          build_rust_ios.sh（先跑 FRB codegen，再编 iOS 静态库）
test/             数据/缓存/并发/离线测试 + test/ui/ 按页面拆分的 UI 测试 + goldens/（23 张）
CONTRACTS.md      页面开发约定（页面清单 / 数据层与存储 API / 路由 / 共享组件 / 测试门禁）
PATCHES.md        Rust 内核相对 fqapp 的 fork 基线、本地补丁清单与上游同步流程
```

## 构建与运行

环境（本机验证用，仓库未锁定工具链）：Flutter 3.47.9、Rust 1.99.1（`rustup target add aarch64-apple-ios`）、Xcode 27.2、CocoaPods 1.17；Dart SDK `^3.13.7`，iOS 部署目标 15.0。

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

Bundle ID `com.lihangyu.novelPlaylet`，显示名「摆烂盒子」。Rust 静态库靠 `ios/Flutter/Release.xcconfig` 的 `-force_load` + `DEAD_CODE_STRIPPING=NO` 链进主二进制，`Info.plist` 已为 `127.0.0.1` 开 ATS 例外（视频回环）。

Android 打包（arm64 单 ABI，出可安装的 release APK；细节见 [docs/android-packaging.md](docs/android-packaging.md)）：

```bash
./scripts/build_rust_android.sh              # 内核 .so → android/app/src/main/jniLibs/arm64-v8a/
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

`android/` 工程、Manifest 的 `INTERNET` 与 `127.0.0.1` 明文回环、备份排除规则、图标和签名配置都已补好；视频/缓存等 Android 运行时行为等业务改造后再按真机验证处理。

真机安装（免费 Apple ID 自签，7 天有效；复用本机已有工具）：

```bash
cd ~/workspace/ios-sideload
BUNDLE_ID=com.lihangyu.novelPlaylet IPA=/Users/lihangyu/workspace/novel-playlet/build/ios/novel_playlet_unsigned.ipa ./all.sh --mint
```

真机出问题时（接口失败/下载失败），直接把 App 容器里的日志和离线数据取出来，不用重装：

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.lihangyu.novelPlaylet \
  --source 'Library/Application Support/backend' --destination /tmp/np-backend
# /tmp/np-backend/rust.log（内核日志）、/tmp/np-backend/config/device_pool.json（设备池，密文）
# 离线下载另取 'Library/Application Support/offline'（diag.log + manifest + mp4）
```

> 本机没有安装 iOS 模拟器 runtime，所以开发验证走「host 测试 + golden 截图 + 真机」。

## 测试

```bash
flutter test                       # 数据解析 + 缓存 + 并发回归 + UI golden 预览（不需要网络/内核/模拟器）
flutter test --update-goldens      # 重新生成 test/goldens/*.png（当前 23 张）
cargo build --manifest-path rust/Cargo.toml   # live probe 需要 host dylib
LIVE_PROBE=1 flutter test test/live_probe_test.dart   # 打真实上游，抓推荐/详情/目录/正文原始 JSON
```

- `test/parsers_test.dart`：字段类型不稳定（数值是字符串、列表是单对象、id 截断）的兼容逻辑。
- `test/video_parsers_test.dart`：短剧卡片/详情/取流的字段兼容与去重。
- `test/feed_concurrency_test.dart`：翻页请求必须串行（真机曾出现同一 offset 每帧连发、并发响应互相覆盖导致列表闪烁），同时锁住状态 copy 不丢字段；另覆盖分类契约（`tab_type` 认领失败、漫剧首页无游标时改用搜索兜底翻页）与「搜索 A 未回就提交 B 时丢弃 A」。
- `test/cache_test.dart`：缓存统计/清理只动可重建缓存，书架、进度与设备池不动。
- `test/offline_downloader_test.dart` / `test/offline_queue_test.dart`：离线单任务下载器（20 章/批、单集失败重试、额度、暂停续传、进程重启恢复）与等待队列（FIFO、去重、上限 20、完成/失败/取消后自动接管、连点并发竞态、失败快照不继承上一个任务进度）。
- `test/video_store_test.dart`：短剧收藏加入/去重/移出、观看进度与最近观看（最多 3 条、同剧去重顶到最前）、写入后 revision 递增。
- `test/ui/`（按页面拆：recommend / home / detail / video / reader / mine / settings / 缓存中心，共享 `test/ui/preview_harness.dart`）：假 transport 注入固定数据，真实渲染各页面成 PNG（`test/goldens/`，23 张：含设置页默认/取色弹层/绯红主题/深色、阅读页设置弹层、首页滚动收起态、短剧选集展开、我的页短剧面板、缓存中心与 M3 删除确认框），并断言三个分类的推荐流/搜索结果封面尺寸与比例一致、分类 tabs 可横向滚动且没有「为你推荐/短剧推荐」旧标题、手势滑切分类、切分类回来保留滚动位置、顶部高度收紧（搜索 40 / tabs 36 / 顶栏 ≤100）、往下浏览收起搜索框且 tabs 保留、回顶自动展开、深滚动时往回滚立即展开、收起后切分类保持收起、搜索态滚动不收起、取消搜索回显快照且不重发请求、失败后换关键词先显示 loading、首屏失败立即显示错误页、搜索框不因清空按钮被撑高、带 `blockIndex` 进入阅读页不落在第一页；另断言封面 Hero 进出详情正反向飞行（含 iOS 手势返回）、详情加载不转圈、信息行合并、短剧选集 36 集一个 tab；以及我的页双面板：悬浮按钮/左右滑动切换、三块阶梯延迟（标题先走、书架块此时不动）、设置入口只有一枚且与缓存入口成组、切换时在屏幕内左右移动、缓存入口在设置左侧且能打开缓存中心、短剧标题镜像、切换中点帧；短剧详情底部收藏/继续观看，我的页短剧收藏与最近观看（最多 3 条）；缓存中心分区/实时进度与网速/暂停失败态/空态/Hero 进详情；设置页不再有离线缓存区块且提示指向缓存页；缓存中心 M3 删除/清空（确认框取消/确认、记录型 fake store 断言 delete/clearAll、同区排队项一并撤掉、另一区不受影响）。
- `test/settings_test.dart`：主题色落盘与恢复（启动预读首帧即生效、旧值不覆盖用户新选择）、`AppAccent` 注入、白/灰/黑中性色不被染成彩色、阅读弹层主色 × 各纸色对比度 ≥ 4.5、真实 `NovelPlayletApp` 跟着主题色重建、预设换色、取色弹层纵向/横向拖动都能改色、清理缓存二次确认/进行中禁用/失败可恢复/清理后占用归零、「我的」右上角设置按钮能打开设置页。
- `test/live_probe_test.dart`：默认跳过；需要先 `cargo build` 出 host dylib，且网络能访问设备注册域名。
- `integration_test/reader_pagination_perf_test.dart`：真机 profile 采集阅读页整章分页/切章的 FrameTiming（不进 `flutter test` 与 CI）；跑法 `flutter drive --profile -d <device> --driver=test_driver/integration_test.dart --target=integration_test/reader_pagination_perf_test.dart`，结论与数据见 [docs/reader-pagination-profile.md](docs/reader-pagination-profile.md)。

> golden 依赖 macOS 系统字体（Arial Unicode / STHeiti），换机器或换系统版本可能不一致。

CI 配置在 `.github/workflows/ci.yml`，包含同一套门禁：`dart format --set-exit-if-changed` / `flutter analyze --fatal-infos` / `flutter test`（macOS runner，golden 需要系统字体），`cargo fmt --check` / `cargo clippy -D warnings` / `cargo test`（Linux）、FRB 绑定漂移校验，以及 iOS 无签名构建 job（`scripts/build_rust_ios.sh` → `pod install` → `flutter build ios --release --no-codesign`，不签名也不安装）。

> **自动触发暂时关闭**：App 还在快速迭代，连续提 PR 时等 CI 影响效率，当前只保留 `workflow_dispatch` 手动触发；稳定后把 `.github/workflows/ci.yml` 顶部的 `push` / `pull_request` 触发器加回来即可。

本地等价门禁：`make check`（Rust/Dart 全套 + 绑定漂移；不含 iOS 构建）；只做格式化用 `make format`。

## 本地数据与缓存

App 沙盒里会落盘的东西（iPhone 13 调试期实测：文稿与数据 400 MB，其中视频缓存 339 MB）：

| 位置（相对 App 沙盒） | 内容 | 上限 / 清理 |
|---|---|---|
| `Application Support/backend/src/` | 播放时下载的剧集（CENC 源保留密文 + 密钥 sidecar，非加密源则明文）、漫画图 | 内核 `MAX_VIDEO_CACHE_BYTES` = **128 MB**（视频与漫画图共用），下载完异步按最旧淘汰，同时最多 2 个下载；单集下载上限 2 GiB |
| `Library/Caches/libCachedImageData/` + `Application Support/libCachedImageData.db` | 封面图磁盘缓存（500–800px 大图也会落到这里）与 sqflite 索引 | 120 个对象 / 7 天；启动时体积 >40 MB 裁到 25 MB |
| `Application Support/reader_chapters/` | 章节正文 JSON（内存再叠 8 章 LRU） | 最多 300 个文件，超出按最旧淘汰；超过 7 天只算过期，仍先展示并后台刷新 |
| `Application Support/offline/novel/` | **离线小说（pinned）**：`<bookKey>/book.json` + 每章 JSON（明文） | 上限 **1 GB**；**永不自动清理**，只在「我的 → 缓存」页删除/清空 |
| `Application Support/offline/video/` | **离线短剧（pinned）**：`<seriesKey>/series.json` + 每集明文 `.mp4` | 上限 **3 GB**；**永不自动清理**，只在「我的 → 缓存」页删除/清空 |
| `Documents/diag.log` | 早期调试探针遗留日志（当前代码不再写入） | 清理时一并删除 |
| `Application Support/backend/config/` | 上游设备注册池、运行时 `config.json` | **不是缓存**：删了要重新注册设备 |
| `Application Support/backend/rust.log` | 内核日志：接口失败（`api xxx failed: ...`）、设备池维护、视频缓存迁移 | 单文件 1 MB、轮转 1 份；仅排查用，可随时删 |
| `Application Support/offline/diag.log` | 离线下载诊断日志（开始/失败/暂停 + 错误文本，不含正文） | 128 KB 轮转一次；仅排查用，可随时删 |
| `Library/Preferences/*.plist` | 书架、阅读进度（含页首段落下标）、最近阅读、阅读设置、主题色 | **用户数据**：不清理 |

「设置 → 存储」会显示当前缓存占用（视频/封面/章节明细）并提供「清理」：只清上面四类可重建缓存，书架与进度不动；**离线缓存不参与这次清理**，统一在「我的 → 缓存」页删除/清空。统计/清理逻辑在 `lib/core/cache/app_cache.dart`，离线区在 `lib/core/storage/offline/`。

「设置 → 主题色」改的是 Material 3 的 seed：primary/secondary/选中态全部跟着派生，阅读页工具栏与目录高亮也会一起变（阅读弹层按纸色明暗单独派生 scheme，避免暗色 App + 浅色纸底时文字看不清）。近中性色（白/灰/黑）走单色方案，不会把白色染成青色、黑色染成粉色。选择落盘在 `shared_preferences`（`app_seed_color_v1`），`main.dart` 在建 MaterialApp 之前先读盘（最多等 300ms），首帧就是用户选的颜色；读盘失败/超时就按默认色走。主题色只负责配色，不提供深色模式开关（跟随系统）。

清理后 App 自身缓存≈0；某次真机观察沙盒里还剩 ~20 MB，是 iOS 自己生成的启动快照（`Library/SplashBoard`）与 Metal 着色器缓存，不归本 App 管理，重装/系统回收时会自动消化。

## 已知限制

1. **首次打开必须联网完成设备注册**（`log.snssdk.com`）。若本机代理/网络拦截该域名，会一直停在「阅读环境启动失败」，可点重试。
2. 离线缓存目前是「前台下载」：任务进行中切后台会暂停（回前台不自动继续），不支持 iOS 后台下载、断点字节续传、选集下载；短剧离线是**明文 mp4**（按需求「能看就行」），小说正文同样是明文；两段式下载峰值磁盘约 2× 单集（稳态只剩离线一份）。同时只跑一个任务，其余排队；**队列只在内存里**（App 重启后等待项消失，重新点缓存会按文件缺口续传）。
3. 无评论/段评/听书/漫画；阅读器只有横向分页，没有滚动跨章。
4. 阅读进度记录到「章 + 页首段落下标」：换字号/换设备重新分页后能回到读到的那一段，但没有精确到页（页号本身随字号变化）。
5. 视频是骨架：起播要等整集下载进内核缓存（流式回环见 [docs/video-playback.md](docs/video-playback.md) M1）；不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕；视频进度只记到「集」、不落盘。退后台不会主动暂停（快速切回继续播，长时间后台由系统挂起）。短剧流走书城首页的 `tab_type=8`（6 部/页、`next_offset` 游标翻页），翻完游标后暂时不会像 fqapp 那样回退到搜索兜底，见 [docs/video-playback.md](docs/video-playback.md) 4.1-5。
6. 漫剧分类的首页流 `tab_type=24` 只有一屏、没有游标，滑到底后的翻页与搜索都借短剧搜索接口（`query=漫剧` / 用户关键词 + `tab_type=11`，按 `genre=205` /「漫剧」标签过滤，见 `lib/features/recommend/content_source.dart` 的 `ManjuSource`）；兜底流的卡片元数据可能不如首页流完整。漫剧点进详情走的是短剧详情路由 `/api/v1/series/{id}`，真实上游尚未验证，失败时详情页会展示错误态。
7. App 全局锁竖屏（阅读器是横向分页、列表也是竖屏布局）；只有播放页的横屏视频才给「全屏」按钮，退出全屏/返回/离开播放页都会恢复竖屏。
8. iOS 上架需处理 GPLv3 与内容授权，不建议按上架排期；当前定位自用/自签。

## 后续扩展点

- **加 tab**：`lib/app/shell/home_shell.dart` 的 `_tabs` 表加一项（底栏与页面由同一张表驱动），页面走 `ConsumerWidget`。
- **加页面**：`lib/app/router.dart` 加一个 `AppRoute` 子类（自带强类型参数 + `toRoute()`），页面里 `context.pushAppRoute(...)`；不要再加字符串路由 / `onGenerateRoute`。
- **Android**：打包链路已就绪（`android/` 工程 + `scripts/build_rust_android.sh`），构建与签名见 [docs/android-packaging.md](docs/android-packaging.md)；Flutter 业务代码无需为打包改动。视频播放（ExoPlayer）与缓存路径等运行时行为等业务改造后再按真机验证处理。
