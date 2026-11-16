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

现状：书架 / 收藏 / 进度已迁到 SQLite（`<AppSupport>/library.db`，四张表：状态/快照 × 小说/短剧），
最近列表由记录派生；云同步走 `<dir>/sync.json` 整包 PUT，载荷 `schemaVersion = 2`。
以下待办按优先级排列，设计层面的评估见 [docs/storage-model-proposal.md](docs/storage-model-proposal.md)。

### P0 数据与正确性

- [x] ~~短剧进度无上限~~（2026-11-16 已随统一记录解决）：小说/短剧共用 `ReadingStore.libraryLimit = 500`，
  只淘汰「未上架且无墓碑」的纯进度行；书架条目与墓碑不参与淘汰。
- [ ] 上传缺 `If-Match`：两台设备同时同步时都读到 rev N、都写 rev N+1，后写覆盖先写。逐条合并能让数据最终收敛，但中间窗口会丢改动且 revision 退化。
  - 建议：`PUT` 带 `If-Match: <etag>`，412/409 时重读 → 重合并 → 重写。
- [ ] tombstone 只增不减：`novel_shelf_meta_v1` / `video_shelf_meta_v1` 每次「加入再移出」都永久留一条（约 50 B，1000 条约 50 KB），且会进同步载荷。书架与短剧收藏本身也没有条数上限。
  - 清理有风险：删掉 tombstone 就丢失删除信息，远端旧值会把已删条目复活。安全做法需要因果稳定性（确认各设备都已同步过该 revision），简化近似是保留 90 天。**改造前先别动**。

- [ ] 进度行裁剪没有墓碑：`libraryLimit` 是直接删行，"缺记录"在合并里不等于"删除"。
  - 单设备没问题（删掉后导出就没有、上传即覆盖）；**双设备下会被对方的远端记录重新补回来**。
  - 方案：状态行加 `progress_pruned_at`，合并时"裁剪时间 > 对方 last_read_at"才丢弃；或只裁剪从未参与同步的行。

### P1 云同步性能

- [ ] 没有条件请求：每次同步无条件 `GET` 全文；`_WebDavResponse` 只保留 statusCode/body，headers 全丢，即使服务器回了 ETag 也拿不到。
- [ ] `revision` / `lastRevision` 只写不读，从未用于短路。
- [ ] `ensureDirectory` 每次同步都重跑 MKCOL（2 次往返），首次成功后可按 config 缓存。
  - 建议：`PROPFIND Depth:0` 取 `getetag` 后比对本地 `remoteEtag`，命中则整轮跳过；取不到时回退到现有内容比对（部分 DAV 实现的 ETag 不可信，必须留 fallback）。

### P2 载荷与遗留清理

- [ ] 同步载荷未压缩：实测 gzip 可压 4.6~5.5 倍（20.4 KB → 4.4 KB）。
- [ ] 未按域拆文件：现在仍是一个 `sync.json`。拆成 `<kind>-state.json` / `<kind>-meta.json`
  后，一次翻页只传状态文件；推荐与 P1 的 `PROPFIND Depth:1` 一起做。
- [x] ~~`last_read_book_v1` 只写不读~~：迁移后已移除，`lastReadBookId()` 一并删除。
- [ ] `webdav_client.dart` 的 `PROPFIND` 分支是死代码（lib 无调用方，仅 test mock 保留）。

### 已完成：统一 library 记录 + SQLite（2026-11-16）

已落地：**单表 `library`**（`type` = `novel` / `playlet`，主键 `'$type/$id'`），
书架、历史、收藏全部由这张表派生；同步载荷 `schemaVersion = 3`，只认当前版本。
墓碑行只清快照不删行；纯进度行上限 500 由两类内容共享。
方案与合并规则见 [docs/storage-model-proposal.md](docs/storage-model-proposal.md)。

原设想「小说 / 短剧各一张表，一条记录聚合元信息 + 书架状态 + 进度 + 缓存状态」。关键前提：内容全部来自上游、
本机没有登录态也没有编辑入口，所以**元信息是"加入书架那一刻的冻结快照"**（`addToShelf` 已存在即早退，
`_writeShelf` 只有 add/remove 两个调用方）。这条前提把记录切成"用户状态（要合并）"和"上游快照（只取值）"两半，
合并规则因此只剩一条线。

收益：同步载荷 -32%（同书 543 → 371 字节）、key 数 8 → 4、两张派生缓存归零。

落地时选了 SQLite 而不是继续用 prefs：状态表（164 B/行）+ 快照表（207 B/行）拆开后，
虽然单次进度落盘只需重写状态表（32 KB，低于原来的 41.6 KB），但 prefs 没有索引、
没有单行 UPDATE，最近列表与书架都要全表解码；SQLite 让 `ORDER BY last_read_at`
走索引，且换机/扩容时不用再重做一次存储迁移。

仍必须保留的复杂度只有两处：`shelf_at` / `shelf_removed_at` 这对时间戳（布尔状态同步必须能表达"删除"），
以及合并函数的收敛性（"本地优先"这类规则会让两台设备永久抖动）。详见
[docs/storage-model-proposal.md](docs/storage-model-proposal.md)。
