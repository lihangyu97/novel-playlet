# 存储模型提案：统一 library 记录

> 状态：待决策，未实现。评审日期 2026-11-16。
> 相关代码：[reading_store.dart](../lib/core/storage/reading_store.dart)、[sync_service.dart](../lib/features/sync/sync_service.dart)。

## 1. 现状

小说 / 短剧两条链各有 4 个 key，共 8 个：

| 职责 | 小说 | 短剧 | 上限 |
|---|---|---|---|
| 书架 / 收藏 | `shelf_books_v1` | `video_shelf_v1` | 无 |
| 删除标记 | `novel_shelf_meta_v1` | `video_shelf_meta_v1` | 只增不减 |
| 进度 | `reading_progress_v1` | `video_progress_v1` | 200 / **无** |
| 最近列表（派生） | `recent_reading_v1` | `video_history_v1` | 3 / 3 |

同一本书在"在读"状态下会同时出现在 3 张表里（书架条目 + 进度条目 + tombstone 条目），
合计约 **543 字节**；两张"最近列表"是纯派生缓存，靠「空表 fallback」和「同步后重建」两处逻辑维持一致。

痛点：

1. 一个实体散落 3 张表，任何不一致都要靠重建逻辑兜（`applySyncData` 里两次 `_recentFromProgress`）。
2. 同一本书的 title/cover 存两遍，同步载荷翻倍。
3. 删除语义（tombstone）寄生在独立表里，容易被新代码漏写。
4. `video_progress_v1` 无上限，见 [TODO.md](../TODO.md) P0。

## 2. 提案

小说 / 短剧各一张表，一条记录聚合"内容元信息 + 用户状态"：

```sql
-- 小说；短剧同构，进度三列换成 episode_index / quality
CREATE TABLE library_novel (
  id               TEXT PRIMARY KEY,
  title            TEXT    NOT NULL DEFAULT '',
  author           TEXT    NOT NULL DEFAULT '',
  cover            TEXT    NOT NULL DEFAULT '',
  color_dominate   TEXT    NOT NULL DEFAULT '',

  -- 进度组：三列共享 last_read_at 这一个时间戳
  last_read_at     INTEGER NOT NULL DEFAULT 0,   -- 0 = 从未读
  chapter_id       TEXT    NOT NULL DEFAULT '',
  chapter_index    INTEGER NOT NULL DEFAULT 0,
  block_index      INTEGER NOT NULL DEFAULT 0,

  -- 书架状态：两个时间戳相加表达"删过"
  shelf_at         INTEGER NOT NULL DEFAULT 0,   -- 0 = 从未加过书架
  shelf_removed_at INTEGER NOT NULL DEFAULT 0    -- > shelf_at 视为已移除
);
```

业务派生（不再需要独立的表）：

| 原来的表 | 新的查法 |
|---|---|
| 书架列表 | `WHERE shelf_at > shelf_removed_at AND shelf_at > 0 ORDER BY shelf_at DESC` |
| 阅读进度 | 按 id 直查 |
| 最近阅读（3 条） | `WHERE last_read_at > 0 ORDER BY last_read_at DESC LIMIT 3` |
| 删除标记 | `shelf_removed_at` 列本身 |
| 是否缓存 | **不查表**，扫 `offline/novel/` 得到 id 集合后 join |

收益（按单本在读的书实测）：

| 项 | 现在 | 提案 |
|---|---|---|
| 表 / key 数 | 4 | 1 |
| 单本占用 | 543 B | 320 B（-41%） |
| 需要重建的派生缓存 | 2 张 | 0 |
| 请求级一致性 | 靠重建 | 结构性保证 |

字段差异确实存在（`author` 对短剧无意义，短剧有 `episode_count` / 实际清晰度档位），
所以**建议两张表而不是一张表加 `kind` 列**——合表会产生大量 null 列，且两类内容的进度语义不同（段 vs 集）。
但两张表共用同一套 record 抽象和 merge 函数。

## 3. 落地前必须先定的四件事

### 3.1 布尔状态必须带自己的时间戳

最容易被简化掉、也最容易丢数据的一点。反例：

```
时间轴 ──────────────────────────────────────►
设备 A：  移除书架 (t=10)                     on_shelf=false
设备 B：  改封面   (t=20)                     on_shelf=true（旧值）
```

如果合并粒度是"记录级 LWW"，B 整条因为 t=20 更新而胜出，**A 的删除被复活**。
所以 `on_shelf` 不能是一个裸布尔 + 一个 `updatedAt`，必须配 `shelf_at` / `shelf_removed_at`。
提案里的两个时间戳就是为此存在的——**简化是把 tombstone 从独立表挪进本表，不是消灭它**。

### 3.2 时间戳按字段组划分，不共用

三条独立的时间轴，合并规则各不相同：

| 字段组 | 合并规则 | 备注 |
|---|---|---|
| `title` / `author` / `cover` / `color_dominate` | 两边非空取其一，都非空取 `last_read_at` 大的一侧 | 上游可能改名/换封面；封面 URL 常带会过期的签名参数 |
| `last_read_at` + `chapter_id` + `chapter_index` + `block_index` | **整组**按 `last_read_at` 取大 | 不能各带时间戳，否则会出现"时间取自 A、位置取自 B"的混搭 |
| `shelf_at` | max | 加入书架时间单调前进 |
| `shelf_removed_at` | max | 删除可表达，且不会被旧值复活 |

### 3.3 本机事实不进同步载荷

- `是否缓存`：换设备后本地没有那些文件，同步过去会让 UI 显示"已缓存"但点开加载失败。
  正确做法是**读时以文件存在为准**——离线区 manifest 已经在做 reconcile（按文件存在校正 `cached`/`completed`），
  缓存中心的列表本来就扫目录，顺手就有。
- `缓存路径`：**不要落盘**。用 `b64url(id)` 确定性推导即可。存绝对路径必然失效——iOS 每次重装沙盒容器 UUID 都变。

### 3.4 记录创建与淘汰规则要先写死

- 只在「加入书架 / 开始阅读 / 开始下载」时建记录，**不能浏览详情页就入库**，否则行数会脱离用户真实意图膨胀。
- 必须有淘汰条件，否则重演 `video_progress_v1` 的无上限问题。建议只淘汰本机：
  `shelf_at == 0 && last_read_at < now-90d && 本地无离线文件`，且**删除本地记录不等于删除云端记录**（另一台设备可能还在读）。
- 上限给个硬值（如 500~1000），超限按 `last_read_at` 淘汰最旧。

## 4. 一个容易被忽略的代价：写放大

现在的写入路径是「400ms 防抖 → 只重写进度表」：

| 模型 | 单次进度落盘要重写的量 |
|---|---|
| 现在 | 进度的 ≤200 条 ≈ 45 KB |
| 统一 + prefs 单 key | **整张 library 表**，1000 条约 250 KB（**6 倍放大**，且在主 isolate） |
| 统一 + SQLite | 单行 UPDATE，几十字节（WAL） |

**结论：统一模型必须配 SQLite（或至少按 id 分片），否则引入一个新的 P0。**
这也是 SQLite 在这个项目里第一次真正有正当性的场景——不是为了同步文件更小，
而是为了「一条记录更新不要重写整张表」，同时让 `ORDER BY last_read_at`、`WHERE shelf_at > ...` 变成索引查询而不是全表解码。

## 5. 迁移路径（建议分两步）

**第 1 步：先修 P0，不动模型。**
`video_progress_v1` 加 200 条上限、上传加 `If-Match`。这两条是纯 bug 面，与模型改造正交，
先做能让第二步的风险显著下降。

**第 2 步：统一模型 + SQLite 本地存储，同步载荷仍导出 JSON。**
- 本地：`sqflite` 两张表（+ 索引 `last_read_at`、`shelf_at`）。
- 同步：仍走 `exportSyncData()` → `sync.json`，**只是 `data` 里的结构换成新记录**。
- `SyncSnapshot.currentSchema` 从 1 升到 2。注意 [sync_snapshot.dart](../lib/features/sync/sync_snapshot.dart)
  的 `tryParse` 里 `schema > currentSchema` 会 return null，旧版本会报「云端同步文件格式不正确，已停止覆盖」——
  这是安全的（不会破坏数据），但意味着**两台设备需要一起升级**，否则旧设备停止同步。上线前要在设置页给这条提示。
- 老 key 保留一个版本做回滚兜底，确认稳定后再删。

## 6. 结论

方向可行，是正确方向的简化：

- 收益是实打实的（表 4→1、载荷 -41%、派生缓存归零、一致性 bug 结构性消失）；
- 风险集中在 §3.1 / §3.2（时间戳语义），这两条定不清楚，就会从"更简单"变成"更简单但会丢数据"；
- 真正的技术前提是 §4——**统一模型的伴侣是 SQLite**，用 prefs 单 key 装整张表会引入写放大。
