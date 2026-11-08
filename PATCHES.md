# PATCHES — Rust 内核与 fqapp 上游的差异登记

本仓库的 `rust/` 是从同仓库族 **fqapp** 整体拷入的（见 [README](README.md)），不是 submodule。
为了让「上游修 bug → 本地能不能跟」「本地改了什么 → 同步时会不会被覆盖」有据可查，
所有对内核的改动都登记在这里。**改 `rust/` 的 PR 必须同时更新本文件的第 3 节。**

## 1. fork 基线

| 项 | 值 |
|---|---|
| 上游仓库 | `fqapp`（GPL-3.0，本机/远端同源） |
| 基线 commit | `aabde536c8621092f13b1a95f52e631b189f9243`（2026-11-02 12:53，Merge PR #236） |
| 本仓库拷入 commit | `3170c55`（2026-11-03，feat: novel-playlet 首版） |
| 拷入时的差异 | `rust/`（`src/`、`tests/`、`Cargo.toml`）与基线**逐字节一致**，无本地改动 |

复核方式（本机有 fqapp checkout 时）：

```bash
# 1) 确认基线没记错：拷入 commit 的 rust/ 应与基线完全一致
git -C ../fqapp archive aabde536c8621092f13b1a95f52e631b189f9243 rust | tar -x -C /tmp/fqbase
git archive 3170c55 rust | tar -x -C /tmp/npbase
diff -rq /tmp/fqbase/rust/src /tmp/npbase/rust/src   # 应为空

# 2) 看当前本地相对基线的全部改动
diff -rq /tmp/fqbase/rust rust -x target
```

## 2. 上游同步流程（每次要收上游改动时）

1. 在 fqapp 找到目标 commit，先看 `git log aabde536..<target> -- rust/` 列出上游改了什么；
2. 逐文件对照本文件第 3 节：**不在表里的文件可以直接取上游版本**；在表里的文件要手工合并，
   合并后必须保留本表的本地改动；
3. 跑 `.github/workflows/ci.yml` 里的全部 Rust 门禁
   （`cargo fmt --check` / `cargo clippy -D warnings` / `cargo test`），
   再用契约测试确认上游行为没变（`mock_upstream_contract` / `router_contract` /
   `full_content_json_snapshot` 等都是锁上游行为的快照）；
4. 更新第 1 节的基线 commit 和第 3 节的补丁清单。

已知待跟进的上游改动（基线之后）：

- `86a45e6`（2026-11-02，PR #241）manga 下一章回退改用 `full` 的章节内容。基线取的是
  #241 **之前**的 master，所以本仓库没有这个修复；漫剧本项目当前不用（App 只用 7 个
  读接口），真要同步时按第 2 节流程取 `rust/src/endpoints/manga.rs` 即可。

## 3. 本地补丁清单（相对基线）

### 3.1 内核路由收口 / loopback 安全（docs/architecture-review.md P1-3）

| 文件 | 本地改动 | 原因 |
|---|---|---|
| `src/dispatch.rs` | 新增 `APP_APIS` + `is_public_loopback_path`；`DEVICE_BOUND_WRITE_APIS` 注释更新 | loopback 只对本机免鉴权暴露 App 用的 7 个读接口 + `/src` + `/health` |
| `src/server.rs` | `handle_request` 在 capability 判定后、读 body 前对非公开路由返回 404 | 同机其他 App 不再能读 fqapp/Legado 兼容面 |
| `tests/loopback_guard.rs` | 重写「读接口全开放」用例为「只有 App 路由开放」；新增兼容面 bare 404 / scoped 200 用例 | 锁住新策略 |
| `tests/static_and_loopback.rs` | account POST 改走能力化 URL；新增 bare `/src` Range→206 | 播放器用无 capability 的 baseUrl，`/src` 必须公开 |
| `tests/common/mod.rs` | `bare_url` 注释更新；filter fixture 删除 | 同策略 |

### 3.2 错误模型加 kind（P1-4）

| 文件 | 本地改动 | 原因 |
|---|---|---|
| `src/error.rs` | `ApiError` 增加 `DeviceFailed/RateLimited/Upstream5xx/Timeout/TooLarge` + `kind()`；HTTP 状态码保持 400/500 | 让 Dart 能按 `bad_input/device_failed/rate_limited/upstream_5xx/timeout/too_large/unknown` 分支 |
| `src/endpoints/base.rs` | 新增 `map_client_error`，把上游/client 错误映射成对应 `ApiError` 变体 | 同上 |
| `src/upstream/client.rs` | `ClientError::Transient{kind}`（Network/Timeout/RateLimited/Upstream5xx）、新增 `ClientError::TooLarge` | 分类来源；重试策略未改 |
| `src/upstream/http.rs` | `TransportError::Timeout` | reqwest 超时识别 |
| `src/upstream/mod.rs` | 相关 re-export / 分类 | 同上 |
| `src/dispatch.rs`、`src/server.rs` | 错误 JSON 统一为 `{"success":false,"error":...,"kind":...}`；基础设施拒绝也带 kind | 与 Dart 的契约 |
| `tests/error_kind_contract.rs` | **新增**：bad_input / upstream_5xx / rate_limited / loopback 封套 / 403、413 的 kind | 锁契约 |

### 3.3 删除 filter 子系统（P2-4：配置全 disabled，永远 no-op）

| 文件 | 本地改动 |
|---|---|
| `src/filter.rs`、`tests/filter_config.rs` | **删除** |
| `src/lib.rs`、`src/api/mod.rs`、`src/endpoints/mod.rs`、`src/endpoints/shuqi/tests.rs`、`src/endpoints/video/unsigned_get_cap.rs` | 去掉 `pub mod filter` / `Ctx.filters` / `FilterManager` / `init` 的 `filter_path` 参数 |
| `src/frb_generated.rs` | 重新生成（FFI `init` 少一个参数）；同时被 rustfmt 格式化（见 3.5） |

Dart 侧配套（不在 `rust/` 内，但同属一次改动）：`lib/core/backend/backend_transport.dart`、
`backend_service.dart` 去掉 `filterPath`；`assets/config/filter.json` 删除。

### 3.4 死引用 / 死配置清理（P2-4）

| 文件 | 本地改动 |
|---|---|
| `src/config.rs` | 删 `algorithm_type` / `Admin`（无任何读取方）；端口缺省 18921→18931，与 `assets/config/config.json`、Dart 侧对齐（P2-2） |
| `src/device/crypto.rs`、`src/endpoints/home.rs`、`src/endpoints/manga/download.rs`、`src/endpoints/video.rs`、`src/endpoints/video/variant_url_shapes.rs`、`tests/playlet_interaction_contract.rs` | 删掉指向 `.agents/notes/**` 等不存在文档的注释引用 |
| `src/lib.rs`、`src/api/mod.rs`、`src/server.rs`、`src/dispatch.rs` | 删掉 `docs/migration/**` 死引用，改指 `CONTRACTS.md` / `docs/*.md` |

### 3.5 构建与生成物（P1-5）

| 文件 | 本地改动 | 原因 |
|---|---|---|
| `build.rs` | **删除**（连带 `Cargo.toml` 的 `cc` build-dependency） | 只引用不存在的 `../native/`，且只在 Windows 生效，属永久死代码 |
| `Cargo.toml` | `description` 改为本项目；删 `[build-dependencies] cc` | 同上 |
| `Cargo.lock` | 跟随 `cc` 移除 | 同上 |
| `src/frb_generated.rs` | 由 `flutter_rust_bridge_codegen` 重新生成（`rust_format: true` 后经过 rustfmt） | CI 的 `cargo fmt --check` / 绑定漂移校验需要 |

### 3.6 真机排障：iOS 也安装落盘 logger（2026-11-07）

| 文件 | 本地改动 | 原因 |
|---|---|---|
| `src/api/mod.rs` | `core_log::install()` 从 `#[cfg(target_os = "android")]` 里移到无条件执行（Android 仍额外镜像 logcat） | 真机出问题时 App 容器里没有 `rust.log`，推荐/详情等接口的业务失败（`dispatch.rs` 的 `api ... failed: ...`）只能靠猜；iOS 加上同一份轮转文件后，`xcrun devicectl device copy from --domain-type appDataContainer` 就能直接取日志定位。host/单测也照旧写到各自临时运行目录，不影响行为 |

### 3.7 回环监听器自愈：iOS 后台 socket 被系统回收（2026-11-08）

原因：Apple [TN2277 *Networking and Multitasking*](https://developer.apple.com/library/archive/technotes/tn2277/_index.html) 的 "Listening Socket" 一节说明，
app 被挂起后系统可能回收其监听 socket 的内核资源；回到前台时该 socket 已不再监听，而进程（以及 FRB/tokio 运行时）仍在运行。
axum 0.8 的 accept 循环对 accept 错误无限重试、永不返回，所以监听任务既不会退出也不会重建，
`127.0.0.1:<port>` 从此一律 `connect()` 被拒（ECONNREFUSED / `NSURLErrorCannotConnectToHost` -1004），
播放器报 "Could not connect to the server."，只有杀进程重启才能恢复 —— 这正是真机短剧起播失败的根因。

| 文件 | 本地改动 | 原因 |
|---|---|---|
| `src/server.rs` | `serve()` 改为 spawn 一个监听监督任务：每 2s 用 TCP connect 探测自己绑定的端口（间隔必须小：Apple 的 `Instant` 基于 `mach_absolute_time`，设备锁屏睡眠期间不前进，大间隔会把恢复拖延到睡眠时长之后）；探测被拒即 abort 内部 `axum::serve` 任务、丢弃旧 socket，并**立即**重绑同一端口（失败才 250ms→5s 退避）。绑定统一走 `bind_listener()`：`TcpSocket::new_v4()` + `set_reuseaddr(true)` + `bind` + `listen(1024)`，初始绑定与每次重绑都带 `SO_REUSEADDR`（旧监听器 accept 过的连接可能在同一端口留 TIME_WAIT，不设会 EADDRINUSE 约 15s）。端口/能力 token/`base_url()` 全部不变，已发给 AVPlayer 的 `/src` URL 继续有效；只在 accepting / reclaimed+rebinding / rebound / stopped 四个状态转换打 info/warn，`rust.log` 可直接看出自愈。对外 `serve()` 与 `LoopbackHandle` 形状不变，`shutdown()` 的 `lifetime.cancel()` 与 `task.abort()` 两条路径都有单测验证会释放端口 | iOS 挂起后系统回收回环监听 socket，播放器 `-1004` 且只有重启进程能恢复 |
| `tests/loopback_reclaim.rs` | **新增**：健康监听不自行结束；监听器死亡后 `connect()` 得到 ECONNREFUSED（不是 HTTP 5xx）；同端口重绑后 `/health` 恢复 | 把 TN2277 的症状模型与恢复路径锁成契约测试 |


## 4. 不在本文件范围内的部分

- `rust/` 之外的 Dart 侧改动（UI/数据层/存储）由 git 历史管理，不需要和上游对齐；
- `rust/target/`、`ios/Frameworks/` 等构建产物不入库。
