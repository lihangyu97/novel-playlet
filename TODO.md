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

## 离线内容导出 / 导入（评估 2026-11-18）

评估"缓存能不能带走"：视频导出 mp4、小说导出 txt、小说导入 txt。完整结论与代码依据见
[docs/offline-export-import-proposal.md](docs/offline-export-import-proposal.md)。

### 结论

| 需求 | 成本 | 结论 |
|---|---|---|
| 视频 → mp4 | 0.5–2d | **技术成本≈0**：离线区落盘的就是明文、自洽、faststart 的标准 mp4；成本全在交付方式、命名、磁盘翻倍 |
| 小说 → txt | 0.5–1d | 便宜：章节字段本来就是纯文本数组，按 manifest 顺序拼即可 |
| 小说 ← txt | 1–4d | 贵在「本地书身份」，不在「转 JSON」（转 JSON 只占约 10%） |

### 待拍板

- [ ] 交付方式：`share_plus`（进依赖白名单）还是改 `ios/Info.plist` 开 `UIFileSharingEnabled`（零依赖但碰 `ios/`）
- [ ] 导入的书是否允许进 WebDAV 同步（决定要不要给记录加 `origin`）
- [ ] 导入区独立（`imported/novel/`）还是复用 `offline/novel/` + `origin` 标记（后者会牵动「清空小说缓存」逻辑）
- [ ] 是否需要「整剧打包 zip」（要加 `archive` 依赖，建议先不做）

### 已知的坑（实现前必须处理）

- 缓存中心「清空小说缓存」走 `clearAll()`，导入的书若放在 `offline/novel/` 会被一起删
- 阅读页对合成 `bookId` 会每章补取一次网络锚点、每次进书刷一次目录，纯损耗；上游限流 40 次/分
- 中文 txt 大量是 GBK/GB18030，Dart 原生只认 UTF-8
- 少数源是 `.m4s`/`.ts`，离线区仍命名 `.mp4`，导出前要按 `ftyp` 校验
