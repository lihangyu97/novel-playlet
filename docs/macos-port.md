# macOS 适配

目标：在 macOS 13+（Apple Silicon + Intel）上跑起同一份 Flutter + Rust 内核，先「能用」，再「好用」。

范围决定：iPad 暂缓（`TARGETED_DEVICE_FAMILY = "1,2"` 已经能跑，只差按宽度重排）；macOS 优先。
任务编号（M#）沿用评审时的清单，方便对照。

## 状态速览

| 阶段 | 内容 | 状态 |
|---|---|---|
| 一、工程与构建 | M1–M6 | ✅ 已完成（**未在本机验证编译**，见「验证记录」） |
| 二、系统集成 | M7–M11 | 🔄 M7 完成；M8 待真机验证；M9–M11 未做 |
| 三、交互 | M12–M17 | ☐ 未做（M12 建议优先） |
| 四、播放 | M18–M19 | ☐ 未做（M19 依赖真机验证） |
| 五、布局 | M21–M26 | ☐ 未做（M21–M23 建议优先） |
| 六、质量与发布 | M27–M30 | ☐ 未做 |

图例：✅ 完成 · 🔄 部分/待验证 · ☐ 未做 · ✂️ 决定不做

## 一、工程与构建

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M1 | `macos/` 工程脚手架 | ✅ | 按 Flutter 3.47.9 官方模板渲染（CocoaPods 模式、SPM 关闭），Bundle ID `com.lihangyu.novelPlaylet`，部署目标 **13.0**（`macos/Runner.xcodeproj` + `macos/Podfile`） |
| M2 | Rust universal 静态库脚本 | ✅ | `scripts/build_rust_macos.sh`：arm64 + x86_64 各编 staticlib → `lipo` → `macos/Frameworks/libfqapi_core.a` |
| M3 | 链接方式 + 内核初始化 | ✅ | `macos/Flutter/Flutter-{Debug,Release}.xcconfig` 用 `-force_load` + `-Wl,-export_dynamic`；`initRustRuntime()` 对 iOS/macOS 统一走 `ExternalLibrary.process()` |
| M4 | 沙盒 entitlements | ✅ | `network.client`（上游 HTTPS）+ `network.server`（内核 127.0.0.1 回环，`/src`、`/health`）；Debug/Profile 另带 `allow-jit` |
| M5 | ATS 本地回环例外 | ✅ | `macos/Runner/Info.plist` 与 iOS 同口径放行 `127.0.0.1` 明文，否则 AVPlayer 播 `/src/*.mp4` 直接失败 |
| M6 | 应用图标 | ✅ | 由 `assets/branding/app_icon_2048.png`（git 历史 `9b9d27c^`）用 `sips` 生成 7 档 png |

## 二、系统集成

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M7 | 版本号方法通道 | ✅ | `MainFlutterWindow.swift` 注册 `novel_playlet/app_version`（与 Dart `app_version.dart`、iOS `AppDelegate.swift`、Android `MainActivity.kt` 同名同方法） |
| M8 | Keychain（设备池密钥） | 🔄 | `flutter_secure_storage` 依赖 Keychain + 签名。**待验证**：若每次启动都重新注册设备，说明拿不到 Keychain → 在 Xcode 的 Runner target 打开 Keychain Sharing（`keychain-access-groups`）再验 |
| M9 | 生命周期补 `hidden` | ☐ | `lib/features/sync/sync_lifecycle.dart` 只听 `resumed`/`paused`；macOS 不发 `paused`，关窗/切后台是 `hidden`，不加则「退后台自动推云同步」在 Mac 上失效 |
| M10 | 窗口尺寸 | 🔄 | 已设最小 900×700 并在过窄时居中给 1200×860；**未做**记住上次大小/位置 |
| M11 | 菜单栏 `PlatformMenuBar` | ☐ | ⌘F 搜索、⌘, 设置、⌘←/→ 翻页、Esc 退全屏；不做也能用 |

## 三、交互

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M12 | 打开鼠标/触控板拖拽 | ☐ **优先** | `lib/app/theme/app_scroll_behavior.dart` 没配 `dragDevices`，Flutter 默认把 mouse 排除 → 阅读页左右翻页、播放页上下换集、推荐 tab 横滑**用鼠标都拖不动**。加 `PointerDeviceKind.mouse / trackpad` |
| M13 | 滚轮 | ☐ | 阅读页接 `PointerScrollEvent` 翻页/滚章节；播放页滚轮调音量（或换集）要定策略 |
| M14 | 键盘快捷键 | ☐ | 阅读：←/→/空格/PageUp/PageDown；播放：空格暂停；Esc 退全屏/关弹层；搜索 ⌘F 聚焦 |
| M15 | 悬停与光标 | ☐ | 卡片 hover + `SystemMouseCursors.click`；图标按钮补 tooltip |
| M16 | 右键菜单 | ✂️ 暂不做 | 书架/收藏/搜索结果的管理菜单 |
| M17 | 下拉刷新替代 | ✂️ 暂不做 | 桌面用 ⌘R 或顶栏按钮（若做 M14 顺带） |

## 四、播放

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M18 | 全屏改窗口全屏 | ☐ | `video_player_page.dart` 靠 `setPreferredOrientations` 转横屏，macOS 上是 no-op → 点「全屏观看」没反应。改成窗口 `toggleFullScreen` |
| M19 | 播放链路实测 | 🔄 待验证 | 回环 HTTP + AVPlayer 同一条链路（`video_player_avfoundation` 是 `sharedDarwinSource`，vendored 的 `defaultRate` 补丁 mac 也生效）；要验的是 ATS + 沙盒 |

## 五、布局

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M21 | 内容最大宽度 | ☐ **优先** | 设置/详情/搜索/评论在 1280 宽下会一行 100+ 字；加「内容列上限 ~720pt 居中」 |
| M22 | 网格列数自适应 | ☐ **优先** | 推荐流列数只来自设置（2/3 档），宽窗口下卡片巨大。改成按宽度算列数，设置项保留为小屏档位 |
| M23 | 阅读器行宽 + 缩放去抖 | ☐ **优先** | 正文宽 = 屏宽 − 40（`reader_page.dart`），Mac 上一条 120 字；窗口缩放会连续重排，需去抖（150–200ms） |
| M24 | 弹层宽度 | ☐ | `AppBottomSheet` 是手机式贴底抽屉，宽窗口下限制 `maxWidth`（~560）或改居中 dialog |
| M25 | 侧边导航 | ✂️ 暂不做 | 宽窗口下换 `NavigationRail` |
| M26 | 详情页双栏 | ✂️ 暂不做 | 左封面+信息 / 右目录+评论 |

## 六、质量与发布

| # | 事项 | 状态 | 落点 / 说明 |
|---|---|---|---|
| M27 | golden 加桌面尺寸 | ☐ | `test/ui/preview_harness.dart` 固定 390×844，加 1280×800 |
| M28 | CI 加 macOS job | ☐ | 照 `.github/workflows/ci.yml` 的 ios job：`flutter build macos --release` |
| M29 | 文档 | 🔄 | README 构建步骤、implementation.md §7.4 已补；本文件随进度更新 |
| M30 | `os_log` | ✂️ 暂不做 | `core_log` 落盘逻辑跨平台可用，不接不影响排障 |

## 验证记录（2026-11-19，本机无 Flutter SDK）

本机网络太慢，没有安装 Flutter（引导需下载数百 MB），所以 **`flutter build macos` 未跑**。已做的静态验证：

| 检查 | 结果 |
|---|---|
| `xcodebuild -list -project macos/Runner.xcodeproj` | ✅ 工程可解析（Runner / RunnerTests / Flutter Assemble 三个 target，Debug/Release/Profile 三个配置，Runner scheme） |
| `plutil -lint` 全部 `*.plist` / `*.entitlements` | ✅ |
| `xcrun swiftc -parse macos/Runner/*.swift` | ✅ |
| `bash -n scripts/build_rust_macos.sh` | ✅ |
| `cargo rustc --release --target aarch64-apple-darwin --crate-type staticlib` | ✅（6m46s，产物正常） |
| `flutter pub get` / `pod install` / `flutter build macos` | ❌ 未跑 |
| `flutter analyze` / `flutter test` | ❌ 未跑 |

## 在你自己机器上接着做

```bash
git fetch && git checkout feat/lhy/macos-target
flutter pub get
./scripts/build_rust_macos.sh        # 出 universal 静态库
flutter build macos --release        # 或 flutter run -d macos
```

跑通之后建议的顺序：**M12 → M18 → M21 → M22 → M23**，再做 M9 / M13 / M14 / M15、M8 与 M19 的实测。

## 已知风险与排查对号

| 现象 | 大概率原因 | 处理 |
|---|---|---|
| 构建时问「迁移到 Swift Package Manager」 | 3.47.9 stable 默认开 SPM | 选否，或 `flutter config --no-enable-swift-package-manager`（与 iOS 的 CocoaPods 保持一致） |
| 链接报 `libfqapi_core.a` not found | 没跑 `build_rust_macos.sh` | 先跑构建脚本（与 iOS 同样不入库） |
| 每次启动都重新注册设备 | Keychain 不可用 | Xcode → Runner target → 打开 Keychain Sharing（M8） |
| 视频黑屏 / `NSURLErrorDomain -1022` | ATS 例外没生效 | 检查 `macos/Runner/Info.plist` 的 `NSExceptionDomains` |
| `/health` 连不上、`/src` 404 | 沙盒缺 `network.server` | 检查 entitlements（Debug/Release 都要） |
| 界面全是「手机放大版」 | M21–M23 未做 | 正常，属于下一阶段 |

## 明确不做

- iPad / 分屏 / 台前调度 / 阅读双页（暂缓，不是否决）
- 多窗口、菜单栏常驻图标、触控栏、Handoff / Spotlight / Services
- 自动更新（Sparkle）、Mac App Store 上架（GPLv3 + 审核）
- 画中画 / 后台播放 / 锁屏控制（README「已知限制」已声明）
- 打印 / 分享 / 导出

## 与已有文档的关系

- 内核 fork 与本地补丁清单见 `PATCHES.md`。当年删掉的 Windows-only 桌面播放器（`desktop_fetch.rs` / `desktop_media.rs`，见 PATCHES §3.11）是 Media3 链路，**macOS 不需要恢复**——Mac 走 AVPlayer + 内核回环。
- 构建产物路径（`build/macos/Build/Products/Release/novel_playlet.app`）与 iOS/Android 的差异见 `docs/implementation.md` §7.4。
