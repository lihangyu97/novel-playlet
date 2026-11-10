# novel-playlet

一个 **小说 / 短剧聚合阅读器**：内容实时来自第三方公开接口，App 自身不存任何内容。
Flutter 写 UI，Rust 内核负责签名、设备池、请求与解密。iOS 优先（自签真机可用），Android 打包链路已打通。

> 内容版权归原作者所有，本项目仅供学习研究，使用后果自负。

## 能做什么

- **推荐**：搜索 + 分类 tabs（小说 / 短剧 / 漫剧），各分类独立推荐流（白底不定高卡片 + 瀑布流，默认双列、设置可切三列；封面按内容域原生比例），翻页、下拉刷新、首屏自动补页。
- **小说**：详情 / 目录 / 书架；详情页书评卡片（首条 + 弹窗看全部）；阅读页真实分页、左右翻页、段评气泡、工具栏「评论」/评论面板（只读）、顶部「加入书架→已在书架（只读，只加不移）/ 缓存小说→缓存中→已缓存（缓存中、已缓存点进缓存中心）」两个文本动作、日间/夜间切换（日间回上次选的浅色纸）、字号行距与 4 种底色、目录跳章、邻章预取、进度续读。
- **短剧**：详情 / 选集 / 收藏；播放页上下集、播完自动下一集、1.0–3.0x 倍速、横屏全屏，已缓存集切集秒开。
- **离线**：整本小说 / 整剧短剧一键下载，断网可读可看；下载进度、网速、排队、暂停/续传集中在「我的 → 缓存」。
- **我的**：小说 / 短剧两块面板（书架 / 收藏 + 最近阅读 / 最近观看）。
- **设置**：主题色（天蓝 / 草绿 / 绯红 + 自定义取色）、深色模式（跟随系统或手动）、首页推荐布局（双列 / 三列，默认双列）、存储占用与清理、离线下载清晰度。

## 架构

```
Flutter UI → Riverpod → ApiClient → BackendTransport
                                        │ flutter_rust_bridge（进程内 FFI）
                                        ▼
                          Rust 内核（签名/设备池/请求/重试/解密）
                             │ HTTPS                    │ 回环 127.0.0.1
                             ▼                          ▼
                          上游接口              /src 视频按 Range 解密 → 播放器
```

签名、设备池、限流、重试、正文解密、CENC 解密全部在 Rust；Dart 只传请求参数和渲染 UI。
详细的请求链路、两条内容链路（缓存 → 分页/播放 → 渲染）、缓存布局与构建说明见
[docs/implementation.md](docs/implementation.md)。

## 构建与运行

环境：Flutter 3.47.9、Rust 1.99.1、Xcode 27+、CocoaPods 1.17；Android 另需 JDK 17、SDK 36、NDK 28.2.13676358。
`flutter_rust_bridge` 两端必须同为 2.13.0。

iOS：

```bash
flutter pub get
./scripts/build_rust_ios.sh     # 编 Rust 内核静态库
pod install
flutter build ios --release --no-codesign
```

Android：

```bash
./scripts/build_rust_android.sh
flutter build apk --release --target-platform android-arm64
```

App 显示名「摆烂盒子」，Bundle ID `com.lihangyu.novelPlaylet`。免费 Apple ID 自签 7 天有效，
真机安装与签名细节见 [docs/implementation.md](docs/implementation.md) §7。

## 测试

```bash
make check    # 等价 CI：Dart format/analyze/test、Rust fmt/clippy/test、FRB 绑定漂移
flutter test  # 数据解析、缓存、并发、存储与 UI golden，不需要网络/内核/模拟器
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/implementation.md](docs/implementation.md) | 唯一实现说明：架构、请求链路、小说/短剧链路、缓存、构建、性能、限制 |
| [CONTRACTS.md](CONTRACTS.md) | 页面开发约定：数据层与存储 API、路由、状态管理、测试门禁 |
| [PATCHES.md](PATCHES.md) | Rust 内核相对 fqapp 的 fork 基线与本地补丁清单 |
| [third_party/README.md](third_party/README.md) | video_player_avfoundation 补丁说明与升级流程 |

## 已知限制

- 首次打开必须联网完成设备注册；短剧起播需要先整集下载进内核缓存（流式起播未做），在线清晰度不可选。
- 离线下载仅前台、单任务、无字节级断点；离线内容明文落盘。
- 不做听书 / 漫画 / 弹幕 / 画中画 / 后台播放 / AirPlay / 锁屏控制；视频进度只记到「集」。
- 段评/书评**只读**：不支持发评论、点赞、回复；纯文本源没有段落锚点时不显示气泡。
  升级前缓存/下载的章节缺段落锚点，气泡开启时会自动补取一次带锚点的正文（断网时保留原文）。
- iOS 长时间挂起可能回收本机回环监听（Apple TN2277，表现为播放必现 -1004、杀进程才恢复）：内核同端口自愈重绑，播放页对 -1004 只做一次有界恢复，仍失败才提示重启 App（见 docs/implementation.md §3.2、§5.7）。
- 播放页倍速在操作行最右；横屏视频的全屏入口是画面下方「全屏观看」（全屏时隐藏）。阅读器默认字号 21、行距 1.8；阅读器工具栏不再放上一章/下一章（点正文左右分区、章边界继续滑动、目录都能切章）。
- Android 播放运行时仍待真机全面验证；iOS 上架需处理 GPLv3 与内容授权，当前定位自用 / 自签。

## 许可

本项目复用 `fqapp` 的 Rust 内核与数据解析逻辑（GPL-3.0），因此整体按 **GPL-3.0** 发布，见 [LICENSE](LICENSE)。
