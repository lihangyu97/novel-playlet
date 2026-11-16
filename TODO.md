# TODO

## Android 全局字重（已完成 2026-11-15）

- 设置页新增「全局字重」滑块，仅 Android 显示/生效，默认 400，范围 300–700，持久化 key `app_font_weight_v1`。
- `AppTheme` 会把完整 `textTheme`、组件主题和页面里写死的强调字重一起平移；iOS 的 effective 值恒为 400，保持原样。
- 阅读器正文默认跟随全局字重；阅读器设置里新增「跟随全局字重」开关，关闭后可单独调 300–800 并覆盖全局。老版本已存过阅读器字重（`reader_font_weight_v1`）的用户迁移为不跟随，避免升级后设置丢失。
- 系统栏、图标、图片内文字按约定不处理。

### 后续可选

- Android 系统字体对中间字重可能做合成，滑杆档位观感不一定完全线性；若要更稳定，可评估打包带完整字重的字体（注意授权和包体）。
- iOS 若要换成统一的跨平台字体，需要另行处理字体文件与授权，不在本次范围内。

## 存储与云同步（评审 2026-11-16，暂不动代码）

现状：书架 / 收藏 / 进度 / 最近列表共 8 个 `SharedPreferences` key（4 张真表 + 2 张 tombstone + 2 张派生缓存），
云同步走 `<dir>/sync.json` 整包 PUT。以下待办按优先级排列，设计层面的评估见
[docs/storage-model-proposal.md](docs/storage-model-proposal.md)。

### P0 数据与正确性

- [ ] `video_progress_v1` 无上限：没有对应小说 `progressLimit = 200` 的淘汰，看过的每部剧永久保留（单条约 213 字节，1000 部 ≈ 231 KB）。
  - 影响：主 isolate 每次 `saveVideoProgress` 全量 `jsonDecode`/`jsonEncode`（P1-7 同类问题）；云同步载荷随"看过的剧数"单调增长，小说侧却封顶。
  - 建议：加 `videoProgressLimit`，在 `saveVideoProgress` 与 `applySyncData` 短剧分支复用 `_pruneProgress`；可选「收藏内的 id 不淘汰」。
- [ ] 上传缺 `If-Match`：两台设备同时同步时都读到 rev N、都写 rev N+1，后写覆盖先写。逐条合并能让数据最终收敛，但中间窗口会丢改动且 revision 退化。
  - 建议：`PUT` 带 `If-Match: <etag>`，412/409 时重读 → 重合并 → 重写。

### P1 云同步性能

- [ ] 没有条件请求：每次同步无条件 `GET` 全文；`_WebDavResponse` 只保留 statusCode/body，headers 全丢，即使服务器回了 ETag 也拿不到。
- [ ] `revision` / `lastRevision` 只写不读，从未用于短路。
- [ ] `ensureDirectory` 每次同步都重跑 MKCOL（2 次往返），首次成功后可按 config 缓存。
  - 建议：`PROPFIND Depth:0` 取 `getetag` 后比对本地 `remoteEtag`，命中则整轮跳过；取不到时回退到现有内容比对（部分 DAV 实现的 ETag 不可信，必须留 fallback）。

### P2 载荷与遗留清理

- [ ] 同步载荷未压缩：实测 gzip 可压 4.6~5.5 倍（20.4 KB → 4.4 KB）。
- [ ] 未按域拆文件：书架 / 进度 / 短剧各自 PUT，可避免无关重传。
- [ ] `last_read_book_v1` 只写不读（`lastReadBookId()` 在 lib 内无调用方），可从本地存储与同步载荷中移除。
- [ ] `webdav_client.dart` 的 `PROPFIND` 分支是死代码（lib 无调用方，仅 test mock 保留）。

### 待决策：是否统一为 library 记录

设想「小说 / 短剧各一张表，一条记录聚合元信息 + 书架状态 + 进度 + 缓存状态」。收益是表数量与同步载荷双降
（现在一本在读的书约占 543 字节，合并后约 320 字节），但落地前必须先定死四件事：布尔状态的时间戳语义、
字段级 vs 记录级合并、本机事实（缓存）不进同步、记录创建与淘汰规则。详见
[docs/storage-model-proposal.md](docs/storage-model-proposal.md) §3。
