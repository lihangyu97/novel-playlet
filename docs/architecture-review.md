# 架构评审与优化清单

- 评审时间：2026-11-06
- 评审基线：`main` @ `7eccb70`（Merge PR #13）
- 评审范围：`lib/**`（不含 `lib/src/rust/` 生成代码）、`rust/src/**`、`rust/tests/**`、`test/**`、构建脚本与配置
- 评审方式：逐文件静态阅读（未运行 `flutter build` / `cargo build`，本机无 Flutter 工具链）。标「推断」的性能结论需要真机 profile 确认
- 规模参考：Dart 手写约 1.39 万行、Rust 约 2.29 万行；58 个 commit 集中在 1 个月内；版本 `0.6.0+14`；Rust 258 个测试函数、Dart 约 120 个（61 个 widget 测试 + 21 张 golden）

本文只记录问题与推荐处理方式，不改任何业务代码。优先级定义：

| 级别 | 含义 |
|---|---|
| P0 | 下一轮就该做，风险低、收益明确（不修会持续付出成本） |
| P1 | 明显问题，需要单独排期 |
| P2 | 建议 / 长期优化，不阻塞当前迭代 |

---

## 0. 结论摘要

| 维度 | 评分 | 一句话结论 |
|---|---|---|
| 分层与架构 | 8/10 | 三层边界清晰，FFI 契约收得很紧，个人项目里少见地干净 |
| 可复用性 | 6/10 | 通用骨架（feed / detail）抽得好，但小说/短剧两条链路大量复制粘贴 |
| 扩展性 | 6.5/10 | 加页面/分类要改 3 处以上；内核是整体 fork，扩展成本被 fqapp 遗留面放大 |
| 性能 | 7/10 | 大结构没问题，几个具体点（图片解码、整页 rebuild、首屏分页）值得修 |
| 工程质量 | 6/10 | 测试写得好，但没有 CI 兜底，lint / clippy / codegen 都不在流程里 |

总体判断：**代码质量明显高于个人项目平均水平**，主要问题不是"烂代码"，而是四类结构性成本：

1. Rust 内核是 fqapp 的整体拷贝，注册了 50 个路由但本项目只用 7 个，文档/配置/构建残留多，且没有与上游同步的机制；
2. Flutter 侧小说 / 短剧是两条镜像链路，卡片、网格、面板、解析器、分页模型都在复制粘贴；
3. 少数性能点：封面按原始尺寸解码、我的页因预取 watch 导致整页重建、阅读器首屏一次性全章分页、本地存储全量重写；
4. 没有质量门禁：258 个 Rust 测试 + 120 个 Dart 测试全靠手动跑，lint 规则几乎是默认值，FRB 绑定没有生成校验。

---

## 1. 值得保留的设计（改的时候不要动）

- **单一业务实现**：FFI 与 loopback HTTP 共用 `rust/src/dispatch.rs`，避免"两套接口逻辑漂移"这个最常见的坑。
- **FFI 契约收得很紧**：`rust/src/api/mod.rs` 只暴露 9 个函数，Dart 只传 `(request_id, method, path, query, body, timeout_ms)`，签名/设备池/重试/限流全在 Rust 侧。
- **竞态处理是认真做过的**：推荐流用 `_generation` 代际丢弃过期响应（`lib/features/recommend/recommend_controller.dart:65`），阅读器用 `_requestToken`，Rust 侧取消用 `Drop` 释放 in-flight 登记（`rust/src/api/mod.rs:437`）。
- **取消 / 超时 / 重试 / 预算有边界**：`race_dispatch` + `budget::within` + `Retry-After` 上限 5s；`unwrap` 基本只出现在测试模块。
- **缓存分层且有淘汰**：章节内存 LRU 8 + 磁盘 300（`lib/features/reader/reader_chapter_cache.dart`）、封面 120 个对象 + 启动按体积裁剪（`lib/core/cache/app_image_cache.dart`）、视频 128MB 后台 `spawn_blocking` 淘汰（`rust/src/endpoints/video.rs:1526`）。
- **安全边界有成文设计**：设备池加密 + Keychain、loopback 的 Host/Origin 校验防 DNS rebinding、写接口 capability（`rust/src/server.rs:146`）。
- **测试分层合理**：Rust 用契约测试 / 快照测试锁上游行为，Dart 用假 transport 做 golden 预览，不需要网络和真机。

---

## 2. 问题清单

### P0

#### P0-1 没有 CI 质量门禁，258 + 120 个测试靠手动跑

- 现状：仓库没有 `.github/`、没有 `Makefile`，README 里的 `flutter test` / `cargo build` 全靠人记。Rust 有 25 个集成测试文件、Dart 有 8 个测试文件 + 21 张 golden，但一次重构后没有任何机制保证它们还绿。
- 影响：这是"长期自用 + 7 天重签"项目最大的可维护性风险；测试写得越多，不跑越浪费。
- 处理方式：加一个最小 workflow（GitHub Actions 或任意 CI），四步就够：
  ```bash
  dart format --set-exit-if-changed lib test
  flutter analyze --fatal-infos
  flutter test
  cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --manifest-path rust/Cargo.toml
  ```
  再加一条**绑定漂移校验**（见 P1-5）：
  ```bash
  flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
  git diff --exit-code lib/src/rust rust/src/frb_generated.rs
  ```
- 验收：PR 上三条绿灯；首次开启时大概率会暴露一批 lint / clippy 问题，先修或先 `allow` 并记 TODO，不要让它长期红着。

#### P0-2 封面按原始尺寸解码（内存 + 滚动流畅度，改动最小）

- 现状：全工程 **0 处** `memCacheWidth` / `cacheWidth` / `ResizeImage`，两个 `CachedNetworkImage` 都是裸用：
  - `lib/app/widgets/novel_cover.dart:65`（列表 108pt、详情 96×132、书架 44pt 都用它）
  - `lib/app/widgets/detail/detail_common.dart:79`（详情页 230pt 高的模糊背景）
- 为什么是问题：封面 URL 虽然优先取 `thumb_url`，但上游仍是 500–800px 甚至 1080–1440 宽、单张 1–3MB 的图（`lib/data/models/json_utils.dart:48` 与 `lib/core/cache/app_image_cache.dart` 的注释都写到了）。在 108pt 的格位里把 1080px 解码成 RGBA，单张约 4–6MB；Flutter 默认 `ImageCache` 上限 100MB，于是**只能装约 20 张**（目标尺寸下能装几百张），表现为来回滑动时反复解码 / 驱逐、掉帧，真机发热也会高一点。
- 处理方式：
  ```dart
  CachedNetworkImage(
    imageUrl: url,
    memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
    maxWidthDiskCache: 720, // 磁盘也别存原图
    ...
  )
  ```
  详情页背景需要更高清晰度，给 `MediaQuery.sizeOf(context).width * dpr * 1.5` 即可，不要原图。
- 验收：真机反复滑动推荐页，`ImageCache.currentSizeBytes` 稳定、不再频繁 `evict`；内存曲线下降。

#### P0-3 我的页在根部 `watch` 只为了预取，导致整页重建

- 现状：`lib/features/mine/mine_page.dart:133` 的 `ref.watch(mineDramaDataProvider)` 只为提前加载。而 `mineDramaDataProvider` 依赖 `readingRevisionProvider`，后者在**每次保存观看进度**时 +1（`lib/core/storage/reading_store.dart:225`）。
- 影响：看剧每换一集 → `MinePage`（两个面板 + 两个动画 + 设置按钮）整体重建一次；它还在 `PageView` 里 keep-alive，看不见也会重建。同源问题：`mineDataProvider`、`mineDramaDataProvider`、`videoShelfStatusProvider`、`videoProgressProvider` 都 watch 同一个全局 revision（`lib/features/mine/mine_providers.dart:48`、`lib/features/video/video_library_providers.dart:14`），一次写入触发 4 路 SharedPreferences 重读 + 重解析。
- 处理方式：
  1. 两行修法：把预取改成 `ref.listen(mineDramaDataProvider, (_, _) {})`，页面不再因数据变化重建；
  2. 正确修法：把 revision 拆成 `novelRevision` / `videoRevision` 两个域，或让 provider 用 `select` 精确到 id，避免"看视频导致小说侧重读"。
- 验收：播放页换集时 `MinePage.build` 不再被调用（打断点或加 debugPrint 验证）。

### P1

#### P1-1 小说 / 短剧两条镜像链路的复制粘贴

详见第 3 节清单。最严重的两处：

- `_NovelPanel` 与 `_DramaPanel` 各约 230 行，`_statsOf` / `_columnsOf` / `_itemWidthOf` / `_itemHeightOf` / `_openDetail` / 底部管理菜单是镜像代码（`lib/features/mine/mine_page.dart:320-546` vs `:554-811`）。
- `NovelGridCard` 与 `VideoCard` 约 90% 同构（`lib/app/widgets/novel_card.dart:29-70` vs `lib/features/video/widgets/video_card.dart:29-74`）。

处理方式：抽 `MediaCard`（封面 + 标题 + 一行元信息）、`ShelfGrid<T>`、`PanelShell<TData>` 三个通用件，小说/短剧只注入数据与元信息。预计删 300–400 行重复，且后续改卡片只改一处。

#### P1-2 短剧详情页与小说详情页用了两套状态方案

- 现状：`DetailPage` 走 Riverpod（`detailBundleProvider` / `detailShelfProvider`，autoDispose + 乐观更新）；`VideoDetailPage` 是 `StatefulWidget` + `FutureBuilder` + 本地 `_future`，在 `initState` 里直接 `ref.read(apiClientProvider)`（`lib/features/video/video_detail_page.dart:45`、`:54`、`:121`）。
- 影响：短剧详情没有 provider 缓存（进两次发两次请求）、没有 autoDispose 语义、重试靠 `setState(_load)`、收藏态是手写 `_toggleShelf`，和小说侧行为会慢慢漂移。
- 处理方式：抽 `videoDetailBundleProvider` 家族（与 `lib/features/detail/detail_providers.dart:32` 对称），收藏复用 `AsyncNotifier` 乐观更新模式，页面退化为纯布局。这也是两页未来合并成一套详情骨架的前置条件。

#### P1-3 内核注册 50 个路由、实际只用 7 个；loopback 把未用路由暴露给本机任意进程

- 现状：`rust/src/endpoints/mod.rs` 的 `register_all` 注册了 50 个 handler，Dart 只用到 7 个：`homepage_recommend / search / book_detail_legacy / directory / content / video_detail / video`（Dart 侧只发 8 个 path，见 `lib/data/api/api_client.dart`）。其余是 fqapp 的 Legado 兼容面（听书、漫画、评论、段评、作者、排行榜、书旗源……），本项目永远用不到。
- 另外：loopback 适配器对**读接口不校验 capability**（`rust/src/server.rs:220`，`capability_ok` 只对 3 个写接口生效）。iOS 上 `127.0.0.1` 是设备级共享的，同机其他 App 只要伪造 `Host: 127.0.0.1:18931` 就能读这 43 个路由和 `/src/*` 解密后的视频/图片。没有账号凭证泄漏，但属于"白送的攻击面"。
- 处理方式（按投入从低到高）：
  1. 在 `dispatch.rs` 加 `ALLOWED_APIS` 白名单，只放行本项目用到的 7 个 + `/src/*`；
  2. 或者用 `cfg(feature = "legado-compat")` 把 43 个路由关掉（默认关闭）；
  3. 中长期把内核拆成 `core`（签名/设备/解密/请求）与 `legado-compat`（其余路由）两个 crate，App 只依赖前者。

#### P1-4 错误模型只有两类，语义在 Rust 里被压平

- 现状：`rust/src/error.rs` 只有 `BadRequest(400)` / `Internal(500)`。上游 401/403（设备失效）、429/5xx（可重试）、体积超限最终都变成 500 + 一句话。Dart 侧只能 `statusCode != 200 → 显示 message`（`lib/data/api/api_client.dart:247`），无法做"换设备 / 退避 / 重新注册"的分支。
- 处理方式：`BridgeResponse` 加 `error_kind`（或 body 里加 `code` 字段），区分 `device_failed / rate_limited / upstream_5xx / timeout / too_large / bad_input`；Dart 的 `ApiException` 带上 `kind`。这是让"重试 / 刷新 / 提示"策略能被写出来的最小改动。

#### P1-5 FRB 代码生成没有进流程，改 `api/` 后会漂移

- 现状：`flutter_rust_bridge.yaml:5` 注释承诺 `scripts/build_rust_backend.ps1 / .sh` 每次构建前跑 codegen，但 `scripts/` 只有 `build_rust_ios.sh`，且它**不跑 codegen**；`rust/build.rs` 引用不存在的 `../native/`（只在 Windows 生效，等于永久死代码）。
- 影响：改 `rust/src/api/*` 后忘记重新生成绑定，会在 Dart 编译期或运行期才炸；改动 `api/mod.rs` 的人不一定知道要跑 codegen。
- 处理方式：① 在 `build_rust_ios.sh` 开头调用 `flutter_rust_bridge_codegen generate`（或在 CI 里做漂移校验，见 P0-1）；② 删掉 `build.rs` 里 Windows 的死分支或补上 `native/`；③ 把 `rust/Cargo.toml` 描述从 "Rust native core for fqapp" 改成本项目。

#### P1-6 阅读器首屏一次性做完整章分页（推断，需 profile）

- 现状：`lib/features/reader/reader_page.dart:579-589` 在 `LayoutBuilder` 里对**整章所有段落**跑 `TextPainter`（`lib/features/reader/reader_pagination.dart:179-196`），量完才开始画第一页。
- 影响（推断）：按每段 0.2–0.5ms、100 段估算，切章有 20–50ms 同步卡顿，长章更差。`TextPainter` 必须在 UI isolate，`compute` 无效。
- 处理方式：① 只量到"首屏 + 2 页"就先渲染，剩余分帧补（`SchedulerBinding.scheduleTask`）；② 或把分页推迟一帧，先展示上一章的页 + 加载提示（现在已有 `loading` 叠加）。收益是切章手感，不是帧率，先 profile 再决定做不做。

#### P1-7 本地存储全量重写且无上限

- 现状：`lib/core/storage/reading_store.dart:259-292` 每次保存进度都 `jsonDecode(整个 progress map)` → 改一条 → `jsonEncode` 写回，同时再全量写 `recent`；progress 表按"读过的书"无上限增长。
- 影响：长尾用户（读了几百本）翻页密集时反复序列化几百 KB，且都在主 isolate。
- 处理方式：progress 按 bookId 分 key（`reading_progress_v1/<id>`）或上 sqflite；至少给 progress 加 LRU 上限（保留最近 200 本）。

#### P1-8 内核 fork 没有上游同步机制

- 现状：README 写"复用 fqapp 的 Rust 内核"，实际是 23k 行整体拷入，没有 submodule、没有记录 fork 基线 commit、没有 patch 清单。
- 影响：fqapp 修了签名/设备注册的 bug 无法回流；本项目对内核的改动（如 CENC 流式解密）也无法区分"上游代码 / 本地补丁"。
- 处理方式：至少记录 fork 基线 commit + 维护一份 `PATCHES.md`（本仓库改了哪些文件、为什么）；中期按 P1-3 拆 crate，只同步 core 部分。

### P2

| # | 问题 | 证据 | 推荐处理 |
|---|---|---|---|
| P2-1 | 路由是字符串 + 强转，传错 args 运行时崩溃 | `lib/app/router.dart:95` 起 `settings.arguments as DetailArgs` | `sealed class AppRoute` + 泛型 `push<T>`；个人项目先做到类型化即可 |
| P2-2 | 端口三个来源且默认值不一致：内核缺省 18921，其余 18931 | `rust/src/config.rs:41` vs `lib/core/backend/backend_transport.dart:34`、`assets/config/config.json` | 让内核只认 config.json 的 port（缺就报错），或三处共享一个常量 |
| P2-3 | `app/feed` 层位偏了：`FeedState` 依赖 `data/models/json_utils.dart`，本质是推荐页骨架 | `lib/app/feed/feed_state.dart` | 移到 `features/feed/` 或 `core/ui/feed/` |
| P2-4 | 文档漂移：README 里 `test/settings_test.dart` 重复两遍；`lib.rs:17`、`api/mod.rs:5`、`server.rs:22` 引用的 `.agents/notes/**`、`docs/migration/**` 不存在；`assets/config/config.json` 留着 fqapp 字段；`filter.rs` 永远 no-op（配置全 disabled） | 见各文件 | 删死引用/死配置，或补上文档；README 去重 |
| P2-5 | iOS 侧测试是空壳，播放器（AVPlayer 拉 `/src`）无自动化覆盖 | `ios/RunnerTests/RunnerTests.swift` | 加一个 host 测试：起内核 → 带 `Range` 请求 `/src/...` → 校验 206 + 字节 |
| P2-6 | `test/ui_preview_test.dart` 单文件 1999 行；golden 依赖系统字体 | `test/ui_preview_test.dart` | 按页面拆成 `test/ui/*_test.dart`；golden 只留少量布局快照，行为断言用 find/pump |
| P2-7 | 书架网格 `shrinkWrap`，一次性布局全部条目 | `lib/features/mine/widgets/mine_shelf_grid.dart:52-61` | 书架超过 ~200 本时换 `SliverGrid`；块动画用 `SliverOpacity` |
| P2-8 | 设置页统计串行 stat 400+ 文件 | `lib/core/cache/app_cache.dart:121-132`、`:176-186` | `Future.wait` 分批并发，或聚合目录大小 |
| P2-9 | 模型缺 `==` / `hashCode`，`FeedState` 也没有 | `lib/data/models/novel_item.dart`、`video_series.dart` | 接 `select` 或做 diff 更新前补上 |
| P2-10 | 解析逻辑分散两层：`parseVideoSeries` 在 model，`parseNovelItems/parseSearchNovels` 在 api_client | `lib/data/api/api_client.dart:307-390` vs `lib/data/models/video_series.dart:110-181` | 统一到 `data/parsers/` 或统一到 model，二选一 |
| P2-11 | 分类枚举内嵌上游怪癖（漫剧借短剧 tab、`genre=205`），实现散在 ApiClient 4 个方法 | `lib/features/recommend/recommend_category.dart:12-61`、`lib/data/api/api_client.dart:74-137` | 引入 `ContentSource` 策略对象（feed/search/parse/detailRoute），enum 只留 label/icon |

---

## 3. 可复用性重复清单

| # | 重复项 | 证据 | 建议抽象 |
|---|---|---|---|
| 1 | 小说卡 / 短剧卡约 90% 同构（封面 + 两行标题 + 一行元信息） | `lib/app/widgets/novel_card.dart:29-70` / `lib/features/video/widgets/video_card.dart:29-74` | `MediaCard(cover, title, metaLine, heroTag, onTap)` |
| 2 | 书架网格 / 收藏网格几乎逐行一样 | `lib/features/mine/widgets/mine_shelf_grid.dart:50-78` / `mine_drama_shelf_grid.dart:47-73` | `ShelfGrid<T>(items, cardBuilder, onOpen, onLongPress)` |
| 3 | 我的页两个面板各约 230 行，方法级镜像 | `lib/features/mine/mine_page.dart:320-546` vs `:554-811` | `PanelShell<TData,TItem>` + 注入 dataProvider / title / statsOf / grid / menu |
| 4 | 两个递归卡片解析器（遍历 key 白名单、深度上限、去重逐字重复） | `lib/data/api/api_client.dart:307-355` / `lib/data/models/video_series.dart:110-181` | `walkCards(payload, adapter)`，adapter 只给 id/title/cover keys |
| 5 | 三个同形分页模型 | `lib/data/models/novel_item.dart:77-91`、`video_series.dart:50-64`、`:248-255` | `FeedPage<T>{items, nextOffset, sessionId}` |
| 6 | `RecommendItem` 可空双字段 + 6 处 `video!` | `lib/features/recommend/recommend_item.dart:24-40`、`recommend_page.dart:344` | Dart 3 `sealed class RecommendItem` + `switch`，强转消失 |
| 7 | 两个"最近"条目壳 | `mine_recent_reading.dart` / `mine_recent_watching.dart`（tile 已共用，正例） | 泛型 `RecentList<T>` 包住 `MineRecentTile` |
| 8 | 分类枚举 → 3 处 `if (isNovel / usesManjuSearch)` 分支 | `recommend_controller.dart`、`api_client.dart`、`recommend_page.dart` | 见 P2-11 的 `ContentSource` |

---

## 4. 扩展性成本表

| 场景 | 现状成本 | 建议 |
|---|---|---|
| 加一个 tab | `lib/app/shell/home_shell.dart:28-39` 与 `PageView.children` 两处手改（注释自己承认） | 单一 `List<(Destination, WidgetBuilder)>` 驱动 |
| 加一个页面 | `AppRoutes` 常量 + `onGenerateRoute` case + import 三处，无类型检查 | `sealed class AppRoute` + 泛型 `push<T>` |
| 加一个内容分类 | `RecommendCategory` enum + controller 3 处分支 + ApiClient 4 个方法 + 页面 sliverBuilder 分支 | `ContentSource` 策略对象 |
| 加一个内容源（漫画/听书） | Rust：`router.rs` match + 新 endpoint + `register_all`；Dart：model + parse + api + page + router + 卡片，全部手写 | 短期先把上游怪癖从 enum 挪进 ApiClient 策略类 |
| 跟随 fqapp 更新内核 | 无机制（P1-8） | 记录基线 commit + `PATCHES.md`，中期拆 crate |

---

## 5. 性能清单

### Flutter

| 级别 | 项 | 证据 | 说明 |
|---|---|---|---|
| P0 | 封面未限解码尺寸 | `lib/app/widgets/novel_cover.dart:65`、`detail_common.dart:79` | 见 P0-2 |
| P0 | 我的页根部预取 watch | `lib/features/mine/mine_page.dart:133` | 见 P0-3 |
| P1 | 阅读器首屏全章分页 | `lib/features/reader/reader_page.dart:579-589` | 见 P1-6（推断，需 profile） |
| P1 | ReadingStore 全量重写 | `lib/core/storage/reading_store.dart:259-292` | 见 P1-7 |
| P2 | AppCache 串行 stat | `lib/core/cache/app_cache.dart:176-186` | 见 P2-8 |
| P2 | 书架 shrinkWrap | `mine_shelf_grid.dart:52-61` | 见 P2-7 |

列表本身的实现是好的，不用改：sliver + `SliverChildBuilderDelegate`、固定 `mainAxisExtent`（避开 `childAspectRatio` 在大字号下的溢出）、`PageView` keep-alive + `RepaintBoundary`、阅读器分页结果按 `(章节, 宽高, 字号, 行距, 字体)` 缓存（`_PaginationKey`），都做到了应有的水平。

另外两项是**合理取舍，不建议动**：`main.dart` 首帧前最多等 300ms 读主题色（换来首帧不闪色）；`Grid`/`Align` 这类小布局的 `setState` 频率。

### Rust

结论：**这块不需要优化**。取消/超时/重试/预算、`std::fs` 只出现在 `spawn_blocking`、下载 `Semaphore(2)`、gunzip 有界且独立 semaphore、Range 流式解密、请求/响应 body 上限都做到了。两个可接受的小点：

- `init` 里 `migrate_plaintext_video_cache` 同步扫目录（`rust/src/api/mod.rs:170`），只跑一次；
- FFI 每次 request 有一次 `Vec<u8>` 拷贝，业务请求体都很小。

---

## 6. 工程质量

| 级别 | 项 | 现状 | 建议 |
|---|---|---|---|
| P0 | 无 CI | 无 `.github/`、无 `Makefile` | 见 P0-1 |
| P1 | lint / clippy 全默认 | `analysis_options.yaml` 只有 `flutter_lints`；`rust/` 无 clippy.toml / rustfmt.toml | 加 `prefer_const_constructors`、`unawaited_futures`、`avoid_dynamic_calls`、`require_trailing_commas`；CI 跑 `clippy -D warnings` |
| P1 | 测试文件过大 | `test/ui_preview_test.dart` 1999 行 / 61 个 widget 测试 | 按页面拆分，golden 只用少量布局快照 |
| P1 | 生成代码无校验 | `lib/src/rust/` + `frb_generated.rs` 入库，但 codegen 不在流程里 | 见 P1-5 |
| P2 | iOS 原生测试空壳 | `ios/RunnerTests/RunnerTests.swift` | 见 P2-5 |
| P2 | 文档与实现不一致 | 见 P2-4 | 每次改动顺手同步，或在 CI 加文档链接检查 |
| — | 依赖锁定 | `pubspec.lock` / `Cargo.lock` 均入库 | 保持 |

---

## 7. 按投入产出比排序（建议的执行顺序）

| # | 事项 | 预估成本 | 收益 | 关联 |
|---|---|---|---|---|
| 1 | 加 CI（analyze / test / clippy / codegen 校验） | 0.5d | 现有测试变成保护网，防回归 | P0-1 / P1-5 |
| 2 | 封面解码限尺寸 | 0.5d | 内存与滚动流畅度立竿见影 | P0-2 |
| 3 | 修我的页预取 watch + 拆 revision | 0.5d | 少一整页重建 + 少 4 次磁盘读 | P0-3 |
| 4 | 抽 `MediaCard` / `ShelfGrid` / `PanelShell`、合并 `FeedPage<T>` | 2d | 删约 300–400 行重复 | P1-1 |
| 5 | 短剧详情页改用 provider | 1d | 消除两套状态方案 | P1-2 |
| 6 | 内核收口：只暴露 `/src` + 7 个路由，删死配置/死文档 | 1–2d | 缩小攻击面 + 降维护成本 | P1-3 / P2-4 |
| 7 | 错误模型加 `kind` | 1d | 重试/换设备策略可写 | P1-4 |
| 8 | ReadingStore 分片或加 LRU 上限 | 1d | 去掉主 isolate 的大 JSON 重写 | P1-7 |
| 9 | 阅读器首屏分页分帧（先 profile 确认） | 1–2d | 切章手感 | P1-6 |
| 10 | 路由参数类型化 | 0.5d | 消除运行时强转崩溃 | P2-1 |

### 建议分两批

- **第一批（低风险高收益，约 1.5–2 天）**：#1、#2、#3、#6 —— 不动业务逻辑，改完跑一遍全量测试即可。
- **第二批（重构，先补测试再动）**：#4、#5、#7、#8、#10 —— 涉及跨 feature 抽取，改完必须跑 golden 和 Rust 全量测试。
- **观察项**：#9（先 profile 再决定）。

### 明确不建议做

- 引入 go_router / get_it 之类大件（当前规模不值）；
- 给 JSON 解析上 isolate（响应都很小，收益低于复杂度）；
- 对 Rust 内核做结构性重写（先按 P1-3 收口面，再谈拆 crate）；
- 为了"复用"去动 `lib/app/shell/floating_navigation_bar.dart`（778 行，是从 PiliPlus 改造的完整 `NavigationBar` 实现，保留原注释与版权声明是对的）。

---

## 8. 复现与验证

本机无 Flutter 工具链，以下命令在有环境的机器上执行：

```bash
# 基线
git log --oneline -1                 # 7eccb70
wc -l $(git ls-files 'lib/**/*.dart' 'rust/src/**/*.rs') | tail -1

# 现状检查
flutter analyze
flutter test
cargo fmt --check --manifest-path rust/Cargo.toml
cargo clippy --all-targets --manifest-path rust/Cargo.toml -- -D warnings
cargo test --manifest-path rust/Cargo.toml

# 关键事实复核
grep -rn "memCacheWidth\|cacheWidth\|ResizeImage" lib   # 0 处
grep -rhoE 'add_route\("[a-z0-9_]+"' rust/src/endpoints | wc -l   # 50
grep -rhoE "'/api/v1/[^']*'" lib | sort -u                       # 8 个 path
grep -n "18921" rust/src/config.rs                                # 与 18931 不一致
ls .github 2>&1                                                   # 不存在
```

---

## 9. 落地情况（2026-11-06）

> 上文保持评审当时的快照，不做修改；本节只记录 2026-11-06 第一/二批重构与真机 profile 之后的落地状态。
> 对应提交：`8df6c00`（第一批：CI / 封面解码 / 我的页 / 内核收口）、`b2e833e`（第二批：去重 + 错误模型 + 存储/路由 + PATCHES）、`5995bf0`（P1-6 真机 profile 决策）。

### 9.1 已落地

| 评审项 | 落地方式 | 当前证据（文件） |
|---|---|---|
| P0-1 | GitHub Actions 四类门禁（Dart format/analyze/test、Rust fmt/clippy/test、FRB 漂移校验、iOS 无签名构建）+ 本地 `make check`；codegen 也钉进 iOS 构建脚本 | `.github/workflows/ci.yml`、`Makefile`、`scripts/build_rust_ios.sh` |
| P0-2 | 封面按目标显示尺寸解码：`NovelCover` 统一 `memCacheWidth: width * dpr` + 磁盘限宽；详情背景单独按屏宽给解码宽 | `lib/app/widgets/novel_cover.dart`、`lib/app/widgets/detail/detail_common.dart` |
| P0-3 | 我的页根部预取由 `watch` 改 `listen`；存储 revision 拆成 `novelRevision` / `videoRevision`，短剧写入不再触发小说侧重读 | `lib/features/mine/mine_page.dart`、`lib/core/storage/reading_store.dart` |
| P1-1 | 抽出 `MediaCard` / `ShelfGrid<T>` / `RecentList<T>` / `PanelShell<TData>`，小说/短剧只注入数据与文案；第 3 节 8 项重复全部落地（`walkCards`、`FeedPage<T>`、sealed `RecommendItem`、`ContentSource` 等） | `lib/app/widgets/media_card.dart`、`lib/features/mine/widgets/`、`lib/data/parsers/card_walker.dart`、`lib/data/models/feed_page.dart`、`lib/features/recommend/recommend_item.dart`、`lib/features/recommend/content_source.dart` |
| P1-2 | 短剧详情改 provider 化：`videoDetailBundleProvider` 拉详情 + 选集，`VideoShelfController` 做收藏乐观更新，与小说详情 `lib/features/detail/detail_providers.dart` 对称；页面退化为纯布局 | `lib/features/video/video_detail_providers.dart`、`lib/features/video/video_library_providers.dart` |
| P1-3 | 采用白名单方案：`APP_APIS` 只放 7 个 App 读接口，加上 `/health`、`/src/*` 免 capability；其余 loopback 路由对无 capability 调用直接 404（FFI 不受影响），设备绑定写接口仍要 capability | `rust/src/dispatch.rs`、`rust/src/server.rs`、`rust/tests/loopback_guard.rs` |
| P1-4 | 错误模型加 `kind`：Rust `ApiError` 区分 `bad_input` / `device_failed` / `rate_limited` / `upstream_5xx` / `timeout` / `too_large` / `unknown`，错误 JSON 带 `kind`，Dart `ApiException.kind` 可分支；kind 语义已收口为 `isTransient` / `needsRestart` + 统一文案 `apiErrorCopy`，并有一处行为策略（翻页重试按钮按可重试性显示）；**仍不新增 Dart 自动重试循环**（重试/退避在 Rust） | `rust/src/error.rs`、`lib/data/models/json_utils.dart`、`lib/features/feed/feed_state.dart`、`lib/features/recommend/recommend_controller.dart`、`rust/tests/error_kind_contract.rs` |
| P1-5 | codegen 进 `scripts/build_rust_ios.sh` 与 CI 漂移校验；删除 `rust/build.rs` 及其 `cc` build-dependency；`rust/Cargo.toml` 描述改成本项目 | `scripts/build_rust_ios.sh`、`.github/workflows/ci.yml`、`rust/Cargo.toml` |
| P1-7 | 只做「加 LRU 上限」的最小方案：进度表保留最近 200 本（表结构不变，未做 per-book key / sqflite 迁移） | `lib/core/storage/reading_store.dart`（`progressLimit = 200`） |
| P1-8 | `PATCHES.md` 记录 fork 基线（fqapp `aabde536c8621092f13b1a95f52e631b189f9243`）与本地补丁清单/上游同步流程 | `PATCHES.md` |
| P2-1 | 类型化路由：`sealed class AppRoute<T>` + 每个路由一个 `final class` + `context.pushAppRoute(...)`；删除 `AppRoutes` / `onGenerateRoute` / `settings.arguments as XxxArgs` | `lib/app/router.dart`、`lib/app/app.dart` |
| P2-2 | 端口唯一来源是 `assets/config/config.json`（缺省 18931），`rust/src/config.rs`、`lib/core/backend/backend_transport.dart` 与它三处对齐 | `assets/config/config.json`、`rust/src/config.rs`、`lib/core/backend/backend_transport.dart` |
| P2-3 | `app/feed/` 移到 `features/feed/`（列表骨架不再放 app 层） | `lib/features/feed/` |
| P2-4 | 删死文档引用、fqapp 残留配置与死代码（含整个 `filter` 子系统）；README 去重并补当前 API | `assets/config/config.json`、`rust/src/config.rs`、`rust/src/lib.rs`、`README.md` |
| P2-6 | `test/ui_preview_test.dart` 拆成 `test/ui/` 的 7 个页面测试 + `test/ui/preview_harness.dart`；21 张 golden 文件不变 | `test/ui/`、`test/goldens/` |
| P2-8 | `AppCache` 统计改分批并发（每批 `Future.wait`，固定批次避免一次开满），不再逐个串行 stat | `lib/core/cache/app_cache.dart` |
| P2-9 | 模型补 `==` / `hashCode`（`NovelItem` / `VideoSeries` / `FeedPage` / `FeedState`） | `lib/data/models/novel_item.dart`、`lib/data/models/video_series.dart`、`lib/data/models/feed_page.dart`、`lib/features/feed/feed_state.dart` |
| P2-10 | 解析统一到 `lib/data/parsers/`：`lib/data/parsers/card_walker.dart`（递归 + adapter）+ `lib/data/parsers/novel_parsers.dart` / `lib/data/parsers/video_parsers.dart`；model 只留数据 | `lib/data/parsers/` |
| P2-11 | 引入 `ContentSource` 策略对象（`NovelSource` / `DramaSource` / `ManjuSource`），分类 enum 只留 label/searchHint/emptyIcon/source | `lib/features/recommend/content_source.dart`、`lib/features/recommend/recommend_category.dart` |
| 第 4 节「加 tab」 | 底栏项与页面由单张 `_tabs` 表驱动，加 tab 只改这张表 | `lib/app/shell/home_shell.dart` |

### 9.2 未做 / 观察项

| 评审项 | 结论 | 依据 |
|---|---|---|
| P1-6 阅读器首屏整章分页 | **暂不实现**：真机 profile 实测切章只掉 1 帧（150 段/章时中位数约 19ms），不是评审推断的 20–50ms 持续卡顿；分帧补页会让页码跳变，收益不划算。保留观察项，后续若要在意首开手感，优先试「空闲帧预分页下一章」 | `docs/reader-pagination-profile.md`、`integration_test/reader_pagination_perf_test.dart` |
| P2-5 iOS 侧自动化测试 | 本机没有安装 iOS 模拟器 runtime，未补 iOS 单测；内核 `/src` 的 Range 行为已由 Rust 集成测试覆盖（206 / Content-Range / 无 capability 可读），播放器侧仍靠真机回归 | `rust/tests/static_and_loopback.rs` |
| P2-7 书架网格 sliver 化 | 未做：我的页把内容拆成三块做独立横向延迟动画，sliver 无法单独平移，`ShelfGrid` 继续用 `shrinkWrap` 的 `GridView`（个人书架量级可接受） | `lib/features/mine/widgets/shelf_grid.dart`、`lib/features/mine/widgets/panel_shell.dart` |
