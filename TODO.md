# TODO

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
| 上传 `If-Match` / 条件请求 / gzip | ⬜ 未开始 |
| 同步日志（历史 + 明细） | ⬜ 设计完成，待实现 |
| 墓碑回收、进度裁剪墓碑 | ⬜ 需要先定方案 |

### P0 数据与正确性

- [ ] **上传缺 `If-Match`**：两台设备同时同步时都读到 rev N、都写 rev N+1，后写覆盖先写。逐条合并能让数据最终收敛，但中间窗口会丢改动且 revision 退化。
  - 前置：`_WebDavResponse` 目前只留 statusCode / body，要先把 headers 透出来才能拿到 ETag。
  - 做法：`PUT` 带 `If-Match: <etag>`，412 / 409 时重读 → 重合并 → 重写。
- [ ] **墓碑只增不减**：`library` 里 `shelf_removed_at > 0` 的行永不删除。已做的是瘦身（写库时清掉 title / author / cover / intro / episode_count / color_dominate / meta_fetched_at，单行约 370 → 90 B），回收仍是空白。
  - 回收有风险：删掉墓碑就丢失删除信息，远端旧值会把已删条目复活；安全回收需要因果稳定性（确认所有设备都同步过该删除）。
  - 候选方案：远端文件加设备水位 `devices: {deviceId: lastSeenAt}`；或长 TTL（180 天）近似。**动手前先定方案。**
- [ ] **进度行裁剪没有墓碑**：`libraryLimit = 500` 是直接删行，而合并里"缺记录"不等于"删除"。
  - 单设备没问题（删掉后导出就没有、上传即覆盖）；**双设备下会被对方的远端记录补回来**。
  - 做法：状态行加 `progress_pruned_at`（`library.db` 升 v3），合并时"裁剪时间 > 对方 `last_read_at`"才丢弃。
  - 优先级低：500 条上限很少触发。

### P1 云同步性能

- [ ] **没有条件请求**：每次同步无条件 `GET` 全文；`revision` / `lastRevision` 只写不读，从未用于短路。
  - 做法：`PROPFIND Depth:0` 取 `getetag` + `getcontentlength`，本地 `SyncMeta` 存 `remoteEtag`，命中则整轮跳过；取不到时回退到现有内容比对（部分 DAV 实现的 ETag 不可信，兜底必须留）。
  - 顺带：`webdav_client.dart` 里 `if (method == 'PROPFIND')` 是死代码（lib 无调用方，仅 test mock 保留），做这条时一并激活。
- [ ] **`ensureDirectory` 每次同步都重跑**：2 次 MKCOL 往返，首次成功后可按 config 缓存。
- [ ] **同步文件拆分**：~~拆成 `<kind>-state.json` / `<kind>-meta.json`~~ **暂缓，动机已变**。
  - 当初的收益是"一次翻页只传状态部分"，但本地已并成一张表，写放大也已由 SQLite 单行 UPDATE 解决；拆开后一条记录的快照与状态分在两个文件，合并要跨文件 join、还要处理"key 只出现在一边"的情况。
  - 现在拆文件只剩流量收益，而 gzip 已有 4.6~5.5 倍。**先做 P1 + gzip，拿真实流量再决定。**

### 可观测性

- [ ] **同步日志**：设置 → WebDAV 配置弹层 → 「同步记录」页，按时间倒序展示每次同步，
  可展开看具体同步了哪本书、哪个字段。设计见 [docs/sync-log-design.md](docs/sync-log-design.md)。
  - 数据来源：`sync()` 里本来就有 `localData` / `remote.data` / `mergedData` 三份快照，
    两个方向的 diff 纯在 service 层算，不改 `applySyncData` 签名。
  - 存储：`<appSupport>/sync-log.json` 保留最近 50 次；**不进 `library.db`、不进同步载荷**。
  - 前置：`LibraryRecord.diffFrom` 只返回 `bool`，要明细则需加 `changedFields()` 或把比较放在日志层。

### P2 载荷与遗留

- [ ] **载荷未压缩**：实测 gzip 可压 4.6~5.5 倍（20.4 KB → 4.4 KB）。需要先定形态：`sync.json.gz`，还是 `Content-Encoding: gzip`（后者部分 DAV 服务端会重新编码，不可靠）。
- [x] ~~`last_read_book_v1` 只写不读~~：迁移后已移除，`lastReadBookId()` 一并删除。

### 已完成（2026-11-16）

- **统一 library 记录**：8 个 `shared_preferences` key → 单表 `library`；书架 / 历史 / 收藏全部由查询派生，`recent_reading_v1` / `video_history_v1` 与两张 tombstone 表都不再存在。
- **墓碑瘦身**：移出书架只写 `shelf_removed_at`，同时清掉快照列，行不删。
- **删除语义**：`shelf_at` / `shelf_removed_at` 两个时间戳取 max，`shelf_at > shelf_removed_at` 才算在架；合并函数逐字段判等，保证两端收敛。
- **上限**：小说与短剧共享 500 条**纯进度行**额度，书架条目与墓碑不参与淘汰。
- **「我的」页**：小说 / 短剧 tab 合并为「历史 / 收藏」，条目挂绿（小说）/ 橙（短剧）标签，收藏封面统一 3:4。
- **同步载荷** `schemaVersion = 3`：`{'items': [...]}` 单数组，每条带 `type`；导出按主键排序，保证序列化结果稳定。

为什么存储选 SQLite 而不是继续用 `shared_preferences`：prefs 没有索引、没有单行 UPDATE，
最近列表与书架都要全表解码；SQLite 让 `ORDER BY last_read_at` 走索引，换机时也不用再重做一次存储迁移。

仍必须保留的复杂度只有两处：`shelf_at` / `shelf_removed_at` 这对时间戳（布尔状态同步必须能表达"删除"），
以及合并函数的收敛性（"本地优先"这类规则会让两台设备永久抖动）。
