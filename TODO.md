# TODO

## macOS 适配（进行中 2026-11-19）

完整清单、状态与排查对号在 [docs/macos-port.md](docs/macos-port.md)。这里只留速览：

| 阶段 | 状态 |
|---|---|
| 工程与构建（M1–M6） | ✅ 已落地（静态库脚本 / 沙盒 / ATS / 图标 / 部署目标 13.0） |
| 系统集成（M7–M11） | M7 ✅；M8 待真机验；M9–M11 未做 |
| 交互（M12–M17） | ☐ 未做，**M12（鼠标拖拽）优先** |
| 播放（M18–M19） | ☐ 未做：全屏要从「转横屏」改成「窗口全屏」 |
| 布局（M21–M26） | ☐ 未做，**M21–M23（行宽/列数/缩放去抖）优先** |
| 质量（M27–M30） | ☐ 未做 |

分支 `feat/lhy/macos-target`（PR #75）。本机没有 Flutter SDK，`flutter build macos` 还没跑过；
在自己机器上先 `./scripts/build_rust_macos.sh` 再 `flutter build macos --release`。

## Android 全局字重（已完成 2026-11-15）

- 设置页新增「全局字重」滑块，仅 Android 显示/生效，默认 400，范围 300–700，持久化 key `app_font_weight_v1`。
- `AppTheme` 会把完整 `textTheme`、组件主题和页面里写死的强调字重一起平移；iOS 的 effective 值恒为 400，保持原样。
- 阅读器正文默认跟随全局字重；阅读器设置里新增「跟随全局字重」开关，关闭后可单独调 300–800 并覆盖全局。老版本已存过阅读器字重（`reader_font_weight_v1`）的用户迁移为不跟随，避免升级后设置丢失。
- 系统栏、图标、图片内文字按约定不处理。

### 后续可选

- Android 系统字体对中间字重可能做合成，滑杆档位观感不一定完全线性；若要更稳定，可评估打包带完整字重的字体（注意授权和包体）。
- iOS 若要换成统一的跨平台字体，需要另行处理字体文件与授权，不在本次范围内。

## 存储与云同步（评审 2026-11-16）

**现状**：单表 `library`（`type` = `novel` / `playlet`，主键 `'$type/$id'`），书架 / 历史 / 收藏全部由它派生；
云同步是 `<dir>/sync.json` 整包 PUT，载荷 `schemaVersion = 3`（只认当前版本，旧文件直接拒绝）。
设计推演与合并规则见 [docs/storage-model-proposal.md](docs/storage-model-proposal.md)。

### 状态速览

| 项 | 状态 |
|---|---|
| 书架 / 收藏 / 进度迁到 SQLite | ✅ |
| 小说 / 短剧合并单表 + 墓碑瘦身 | ✅ |
| 「我的」页合并为「历史 / 收藏」 | ✅ |
| 短剧进度无上限 | ✅ 随 `libraryLimit = 500` 解决 |
| 上传 `If-Match` / ETag 条件请求 | ✅ |
| `ensureDirectory` 缓存 | ✅ |
| 进度裁剪墓碑（`progress_pruned_at`） | ✅ 库升 v3 |
| 同步日志（历史 + 明细） | ✅ |
| 墓碑回收 | ⬜ 需要先定方案 |
| 载荷 gzip | ⬜ 需要先定形态 |

### P0 数据与正确性

- [x] ~~**上传缺 `If-Match`**~~：PUT 现在带 `If-Match: <etag>`，412 / 409 时重读 → 重合并 → 重写（最多重试一次）。`_WebDavResponse` 已透出 headers。
- [ ] **墓碑只增不减**：`library` 里 `shelf_removed_at > 0` 的行永不删除。已做的是瘦身（写库时清掉 title / author / cover / intro / episode_count / color_dominate / meta_fetched_at，单行约 370 → 90 B），回收仍是空白。
  - 回收有风险：删掉墓碑就丢失删除信息，远端旧值会把已删条目复活；安全回收需要因果稳定性（确认所有设备都同步过该删除）。
  - 候选方案：远端文件加设备水位 `devices: {deviceId: lastSeenAt}`；或长 TTL（180 天）近似。**动手前先定方案。**
- [x] ~~**进度行裁剪没有墓碑**~~：`libraryLimit = 500` 不再删行，改成清空进度并写 `progress_pruned_at`（`library.db` 升 v3）。合并时只有"裁剪时间晚于对方 `last_read_at`"才丢弃；对方之后又读过则复活。
  - 淘汰标记本身没有上限，和书架墓碑一样只增不减；回收方案与墓碑合并处理。

### P1 云同步性能

- [x] ~~**没有条件请求**~~：`PROPFIND Depth:0` 取 ETag，`SyncMeta.remoteEtag` + 本地载荷指纹（FNV-1a）都命中时整轮跳过（不 GET、不 PUT）；取不到 ETag 时用 `If-None-Match` 条件 GET（304 即跳过），再不行回退到无条件 GET + 内容比对。
  - 真机实测（坚果云）：PROPFIND 返回不可用（stat 拿不到 ETag）、GET 也不回 304，所以实际走的是"全量 GET + 内容比对"兜底——不会白 PUT，但省不掉下载。换支持 ETag 的服务端时条件跳过自动生效。
- [x] ~~**`ensureDirectory` 每次同步都重跑**~~：客户端按 `baseUrl + 账号 + 路径` 记住已建目录，首次成功后不再 MKCOL。
- [ ] **同步文件拆分**：~~拆成 `<kind>-state.json` / `<kind>-meta.json`~~ **暂缓，动机已变**。
  - 当初的收益是"一次翻页只传状态部分"，但本地已并成一张表，写放大也已由 SQLite 单行 UPDATE 解决；拆开后一条记录的快照与状态分在两个文件，合并要跨文件 join、还要处理"key 只出现在一边"的情况。
  - 现在拆文件只剩流量收益，而 gzip 已有 4.6~5.5 倍。**先做 P1 + gzip，拿真实流量再决定。**

### 可观测性

- [x] ~~**运行日志**~~：设置 → 诊断 → 「运行日志」页，记录接口报错（method + path + HTTP 状态 + kind + 耗时）与不符合预期的事件（分类不匹配 / 回退纯文本 / 仅远程加密流等），以及 Flutter 未捕获异常。
  - 存储：`<appSupport>/app-log.json` 保留最近 300 条，同摘要 8s 内合并计数；只在本机，不进同步载荷。
  - 入口/页面：`lib/features/logs/app_log_page.dart`；采集在 `ApiClient._getJson` + `lib/core/diagnostics/error_handlers.dart`，不改原有错误处理。
- [x] ~~**同步日志**~~：设置 → WebDAV 配置弹层 → 「同步记录」页，按时间倒序展示每次同步，
  可展开看具体同步了哪本书、哪个字段。设计见 [docs/sync-log-design.md](docs/sync-log-design.md)。
  - 数据来源：`sync()` 里本来就有 `localData` / `remote.data` / `mergedData` 三份快照，
    两个方向的 diff 纯在 service 层算，不改 `applySyncData` 签名。
  - 存储：`<appSupport>/sync-log.json` 保留最近 50 次；**不进 `library.db`、不进同步载荷**。已实现：run 级结果 / 失败阶段 / 双向字段 diff / 按天分组 / 清空。
  - 前置：`LibraryRecord.diffFrom` 只返回 `bool`，要明细则需加 `changedFields()` 或把比较放在日志层。

### P2 载荷与遗留

- [ ] **载荷未压缩**：实测 gzip 可压 4.6~5.5 倍（20.4 KB → 4.4 KB）。需要先定形态：`sync.json.gz`，还是 `Content-Encoding: gzip`（后者部分 DAV 服务端会重新编码，不可靠）。
- [x] ~~`last_read_book_v1` 只写不读~~：迁移后已移除，`lastReadBookId()` 一并删除。

### 已完成（2026-11-16）

- **统一 library 记录**：8 个 `shared_preferences` key → 单表 `library`；书架 / 历史 / 收藏全部由查询派生，`recent_reading_v1` / `video_history_v1` 与两张 tombstone 表都不再存在。
- **墓碑瘦身**：移出书架只写 `shelf_removed_at`，同时清掉快照列，行不删。
- **历史语义**：移出书架后**没再读** → 不进历史并清快照（瘦身成立的前提）；移出后**继续读**（`last_read_at > shelf_removed_at`）→ 回到历史、保留书名封面，但不加回收藏。
- **删除语义**：`shelf_at` / `shelf_removed_at` 两个时间戳取 max，`shelf_at > shelf_removed_at` 才算在架；合并函数逐字段判等，保证两端收敛。
- **上限**：小说与短剧共享 500 条**纯进度行**额度，书架条目与墓碑不参与淘汰。
- **「我的」页**：小说 / 短剧 tab 合并为「历史 / 收藏」，条目挂绿（小说）/ 橙（短剧）标签，收藏封面统一 3:4。
- **同步载荷** `schemaVersion = 3`：`{'items': [...]}` 单数组，每条带 `type`；导出按主键排序，保证序列化结果稳定。
- **条件请求与并发保护**：ETag + 本地指纹命中整轮跳过；PUT 带 `If-Match`，412/409 重读重合并一次。
- **进度裁剪墓碑**：`library.db` v3 加 `progress_pruned_at`，淘汰改标记不删行。
- **同步日志**：`<AppSupport>/sync-log.json`（最近 50 次），入口在 WebDAV 配置弹层。

为什么存储选 SQLite 而不是继续用 `shared_preferences`：prefs 没有索引、没有单行 UPDATE，
最近列表与书架都要全表解码；SQLite 让 `ORDER BY last_read_at` 走索引，换机时也不用再重做一次存储迁移。

仍必须保留的复杂度只有两处：`shelf_at` / `shelf_removed_at` 这对时间戳（布尔状态同步必须能表达"删除"），
以及合并函数的收敛性（"本地优先"这类规则会让两台设备永久抖动）。

## 设置项云同步（已实现 2026-11-18）

**结论**：设置走**独立** `novel-playlet/<profile>/settings.json`，不给 `sync.json` 加字段，
也不做单一 `AppConfig` / `ConfigProvider` 重构；用 `SettingsSection` 注册表 + 领域 provider。
设计见 [docs/settings-sync-design.md](docs/settings-sync-design.md)，实现见 §11.8。

- 为什么不合并进 `sync.json`：合并是「按类型模型重建 `data`」，旧客户端（`schemaVersion = 3`）
  同步一次就会把 `settings` 静默删掉；bump 到 4 又会让旧客户端整条同步停摆。独立文件两边都不碰。
- 触发：`resumed` / 冷启动拉取，1.6s 去抖 + `paused` + 离开设置页推送（脏才推）；
  手动「立即同步」与保存 WebDAV 配置并行跑书架 + 设置。
- 边界：阅读页 / 播放页 / 设置页在栈顶时不回填（避免重排、改播放速度、开关跳动），
  且不推进 `lastRemoteUpdatedAt`，下次自动重试。
- 白名单：主题 / 字重 / 推荐布局 / 阅读排版同步；倍速与下载清晰度保持本机。
- 一致性：整包 LWW（本地 `settings_local_updated_at_v1` vs 云端 `updatedAt`），
  推送带 `If-Match`，412 重读重判；未知 `v` 停止同步，不降级覆盖。
- 记录：设置同步也进「同步记录」（`scope = settings`），无变化不记，避免刷屏。
- 状态：✅ 已实现；测试见 `test/settings_sync_test.dart`。
