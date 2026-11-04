# novel-playlet

小说阅读 App：**只做小说、先做 iOS**。复用同仓库族 `fqapp` 的 Rust 内核（签名 / 设备注册 / 正文解密 / 上游接口），Flutter 侧重写 UI。

> 内容实时来自第三方公开接口，App 不存任何内容。仅供学习研究，版权归原作者所有；使用后果自负。
>
> 本项目复用了 `fqapp` 的 Rust 内核与数据解析逻辑（GPL-3.0），因此整体按 **GPL-3.0** 发布，见 [LICENSE](LICENSE)。

## 现在能做什么

三个 tab：**推荐** / **视频** / **我的**

| 页面 | 状态 |
|---|---|
| 推荐页：顶部搜索框 + 推荐流（3 列网格、下拉刷新、滚动分页）+ 搜索结果 | ✅ |
| 详情页：封面/书名/作者/分类·状态·字数/评分、简介折叠、标签、目录（前 10 章 + 全部弹层）、开始/继续阅读、加入书架 | ✅ |
| 阅读页：TextPainter 真实分页、左右翻页、点击分区、工具栏、字号/行距/4 种底色、目录跳章、进度保存 | ✅ |
| 短剧页：搜索 + 短剧推荐流（下拉刷新、滚动分页） | ✅ 骨架 |
| 短剧详情页：封面/标题/简介/分类/播放量 + 选集网格 | ✅ 骨架 |
| 播放页：AVPlayer 播放（播放/暂停、进度拖动、上下集、播完自动下一集、横屏视频可全屏），密文由内核 `/src` 按 Range 解密 | ✅ 骨架（先整集缓存后播） |
| 我的页：书架（长按移除）、最近阅读（带章节直达阅读页） | ✅ |
| 流式起播（边下边播）、离线下载管理、听书、漫画、评论、段评、登录、设置页 | ⬜ 后续 |

> 视频方案与边界见 `docs/video-playback.md`：本轮不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕。

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

- **签名、设备池、重试、限流、正文解密全部在 Rust 侧**，Dart 只传 `(method, path, query, body)`，对应 `rust/src/api/mod.rs` 暴露的 9 个函数。
- 上游返回的是**原始 JSON**（Rust 只做正文解密），字段兼容集中在 `lib/data/models/`，页面只消费模型。
- 视频同样由内核解密：`/api/v1/videos/{id}` 把整集下载进加密缓存并返回 `/src/<id>.mp4`，该地址由内核回环按 Range 解密；播放器是 `video_player`（底层 AVPlayer），只拉明文 HTTP。
- 本地状态只有书架/阅读进度（`shared_preferences`），设备池密钥在 Keychain（`flutter_secure_storage`），池文件在 App 私有目录。

### 目录

```
lib/
  app/          主题、路由、三 tab 外壳、启动闸门、共享组件
  core/         后端传输/启动/密钥、书架与进度存储
  data/         接口客户端 + 模型与解析（含 video_series / video_detail / video_source）
  features/     recommend / video / detail / reader / mine
lib/src/rust/   flutter_rust_bridge 生成绑定（勿手改）
rust/           Rust 内核（从 fqapp 整体拷入）
assets/config/  config.json / filter.json / device_pool.example.json
```

## 构建与运行

环境：Flutter 3.47.9、Rust 1.99.1（`rustup target add aarch64-apple-ios`）、Xcode 27.2、CocoaPods。

```bash
flutter pub get

# 1) 编 Rust 内核静态库 → ios/Frameworks/libfqapi_core.a
./scripts/build_rust_ios.sh

# 2) 出未签名 App / IPA
flutter build ios --release --no-codesign
```

真机安装（免费 Apple ID 自签，7 天有效；复用本机已有工具）：

```bash
cd ~/workspace/ios-sideload
BUNDLE_ID=com.lihangyu.novelPlaylet IPA=/Users/lihangyu/workspace/novel-playlet/build/novel_playlet_unsigned.ipa ./all.sh --mint
```

> 本机没有安装 iOS 模拟器 runtime，所以开发验证走「host 测试 + golden 截图 + 真机」。

## 测试

```bash
flutter test                       # 数据解析 + UI golden 预览（不需要网络/内核/模拟器）
flutter test --update-goldens      # 重新生成 test/goldens/*.png
LIVE_PROBE=1 flutter test test/live_probe_test.dart   # 打真实上游，抓推荐/详情/目录/正文原始 JSON
```

- `test/parsers_test.dart`：字段类型不稳定（数值是字符串、列表是单对象、id 截断）的兼容逻辑。
- `test/video_parsers_test.dart`：短剧卡片/详情/取流的字段兼容与去重。
- `test/ui_preview_test.dart`：假 transport 注入固定数据，真实渲染四个页面成 PNG（`test/goldens/`）。
- `test/live_probe_test.dart`：默认跳过；需要先 `cargo build` 出 host dylib，且网络能访问设备注册域名。

## 已知限制

1. **首次打开必须联网完成设备注册**（`log.snssdk.com`）。若本机代理/网络拦截该域名，会一直停在「阅读环境启动失败」，可点重试。
2. 没有离线缓存：正文每次实时拉取（缓存是后续功能，`data/` 层已留出扩展位）。
3. 无评论/段评/听书/漫画；阅读器只有横向分页，没有滚动跨章。
4. 阅读进度记录到「章」级别，未记录页内偏移。
5. 视频是骨架：起播要等整集下载进内核缓存（流式回环见 `docs/video-playback.md` M1）；不做画中画/HDR/后台播放/AirPlay/锁屏/清晰度切换/弹幕；视频进度暂不落盘。退后台不会主动暂停（快速切回继续播，长时间后台由系统挂起）。短剧流走书城首页的 `tab_type=8`（6 部/页、`next_offset` 游标翻页），翻完游标后暂时不会像 fqapp 那样回退到搜索兜底，见 `docs/video-playback.md` 4.1-5。
6. iOS 上架需处理 GPLv3 与内容授权，不建议按上架排期；当前定位自用/自签。

## 后续扩展点

- **加 tab**：`lib/app/shell/home_shell.dart` 的 `_destinations` / `_pages` 各加一项，页面走 `ConsumerWidget`。
- **加页面**：`lib/app/router.dart` 加一条 `AppRoutes`。
- **Android**：内核已是 `cdylib`，需补 `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/libfqapi_core.so`（参照 fqapp 的 `scripts/build_rust_backend.sh`），NDK 与 ABI 的坑见 fqapp `DEVELOPMENT.md`；Flutter 侧代码无需改动。
