# 存储模型提案：统一 library 记录

> 状态：待决策，未实现。评审日期 2026-11-16（rev 2：补充"元信息不可变"前提后修正结论）。
> 相关代码：[reading_store.dart](../lib/core/storage/reading_store.dart)、[sync_service.dart](../lib/features/sync/sync_service.dart)。

## 1. 前提：元信息是**冻结快照**

内容全部来自上游（fanqie），本机没有登录态、也没有任何编辑封面 / 书名的入口。更进一步，
读代码可以确认**现在的实现早就是这个语义**：

- [`addToShelf`](../lib/core/storage/reading_store.dart#L187-L196) 在书已在架上时直接 `return`，不刷新已有条目；
- `_writeShelf` 只有 `addToShelf` / `removeFromShelf` 两个调用方，没有任何 update 路径。

所以 title / author / cover 是「加入书架那一刻的只读快照」，只用于断网渲染和上游下架后的兜底
（无登录态，这份快照常常是唯一的一份）。**这是本提案成立的关键前提**：它把记录一刀切成两半，
一半是"用户状态"（必须合并），一半是"上游快照"（只需取值）。

## 2. 现状

小说 / 短剧两条链各有 4 个 key，共 8 个：

| 职责 | 小说 | 短剧 | 上限 |
|---|---|---|---|
| 书架 / 收藏 | `shelf_books_v1` | `video_shelf_v1` | 无 |
| 删除标记 | `novel_shelf_meta_v1` | `video_shelf_meta_v1` | 只增不减 |
| 进度 | `reading_progress_v1` | `video_progress_v1` | 200 / **无** |
| 最近列表（派生） | `recent_reading_v1` | `video_history_v1` | 3 / 3 |

同一本书在"在读"状态下会同时出现在 3 个 key 里（书架条目 + 进度条目 + tombstone 条目），
合计约 **543 字节**，title / cover 各存了两遍。两张"最近列表"是纯派生缓存，
靠「空表 fallback」和「同步后重建」两处逻辑维持一致。

## 3. 提案

小说 / 短剧各两张表，按**生命周期**拆（不是按业务拆）：

```sql
-- ① 用户状态：每次翻页 / 换集都在写，行小、写得最频繁
CREATE TABLE library_novel_state (
  id               TEXT PRIMARY KEY,
  last_read_at     INTEGER NOT NULL DEFAULT 0,   -- 0 = 从未读；进度组的时间戳
  chapter_id       TEXT    NOT NULL DEFAULT '',
  chapter_index    INTEGER NOT NULL DEFAULT 0,
  block_index      INTEGER NOT NULL DEFAULT 0,
  shelf_at         INTEGER NOT NULL DEFAULT 0,   -- 0 = 从未加过书架
  shelf_removed_at INTEGER NOT NULL DEFAULT 0    -- > shelf_at 视为已移除
);

-- ② 上游快照：只在加入书架时写一次，之后只读
CREATE TABLE library_novel_meta (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL DEFAULT '',
  author          TEXT NOT NULL DEFAULT '',
  cover           TEXT NOT NULL DEFAULT '',
  color_dominate  TEXT NOT NULL DEFAULT '',
  meta_fetched_at INTEGER NOT NULL DEFAULT 0
);
```

短剧同构，进度三列换成 `episode_index`（+ `quality_max_height`）。

业务派生（不再需要独立的表）：

| 原来的 key | 新的查法 |
|---|---|
| 书架列表 | `state WHERE shelf_at > shelf_removed_at AND shelf_at > 0 ORDER BY shelf_at DESC` + 快照表 join |
| 阅读进度 | 按 id 直查 |
| 最近阅读（3 条） | `state WHERE last_read_at > 0 ORDER BY last_read_at DESC LIMIT 3` |
| 删除标记 | `shelf_removed_at` 列本身 |
| 是否缓存 | **不查表**，扫 `offline/novel/` 得到 id 集合后 join |

规模与载荷（单本在读的书，实测）：

| 项 | 现在 | 提案 |
|---|---|---|
| 每条链的 key 数 | 4 | 2（或 1，见 §5） |
| 单本同步载荷 | 543 B | 371 B（**-32%**） |
| 需要重建的派生缓存 | 2 张 | 0 |
| 请求级一致性 | 靠重建 | 结构性保证 |

`category` 可以从快照里去掉：书架卡片显式传了 `fallbackToCategory: false`
（[mine_shelf_grid.dart#L56-L59](../lib/features/mine/widgets/mine_shelf_grid.dart#L56-L59)），
只有首页 feed 卡片用分类顶替作者，而 feed 数据不落盘。

## 4. 合并规则

### 4.1 硬约束：合并函数必须收敛

不是"取个大概"，而是必须满足交换律 + 结合律，否则两台设备会永久抖动。**反例（一定要避免）**：

```
规则：元信息"本地非空优先"
设备 A：local=X, remote=R  → 取 X → 上传 X
设备 B：local=Y, remote=R  → 取 Y → 上传 Y（覆盖 X）
下一轮：A 读到 Y 但 local 仍是 X → 又传 X；B 读到 X 但 local 仍是 Y → 又传 Y
→ 永远收敛不了
```

### 4.2 两类数据、两套规则

| 字段组 | 合并规则 | 为什么 |
|---|---|---|
| `last_read_at` + `chapter_id` + `chapter_index` + `block_index` | **整组**按 `last_read_at` 取大；相等时取远端 | 不能各带时间戳，否则出现"时间取自 A、位置取自 B"的混搭 |
| `shelf_at` | max | 加入时间单调前进 |
| `shelf_removed_at` | max；相等时取远端 | 删除可表达，且不会被旧值复活 |
| `title` / `author` / `cover` / `color_dominate` | 整组按 `meta_fetched_at` 取大；相等时取远端 | 收敛；且为将来"详情页刷新元信息"留出口子 |

### 4.3 为什么 `是否在书架` 不能是裸布尔

这是最容易在"简化"时丢掉的一点：

```
设备 A：移除书架 (t=10)       → onShelf=false
设备 B：改了别的字段 (t=20)   → onShelf=true（旧值）
```

整条记录 LWW 会让 B 胜出，**A 的删除被复活**。所以必须保留 `shelf_at` / `shelf_removed_at` 两个时间戳。
**简化是把 tombstone 从独立表挪进本表，不是消灭它。**

### 4.4 本机事实不进同步载荷

- `是否缓存`：换设备后本地没有那些文件，同步过去会让 UI 显示"已缓存"但点开加载失败。
  读时以文件存在为准——离线区 manifest 已在做 reconcile，缓存中心本来就扫目录。
- `缓存路径`：**不要落盘**，用 `b64url(id)` 确定性推导。存绝对路径必然失效（iOS 每次重装容器 UUID 都变）。

## 5. 写放大：决定"一张表"还是"两张表"

现在的写入路径是「400ms 防抖 → 只重写进度表」。统一成一张表会让单次进度落盘重写整表：

| 方案 | 200 行时单次落盘 | 1000 行时 |
|---|---|---|
| 现在（进度表 ≤200 行） | 41.6 KB | —（封顶 200） |
| 单表（状态+快照混在一起，346 B/行） | **67.6 KB（1.6×）** | 337.9 KB |
| **拆表（只重写状态表 164 B/行）** | **32.0 KB（0.77×，比现在更小）** | 160.2 KB |

结论修正：**在"状态/快照拆表 + 行数上限 500"下，不需要引入 SQLite。**
拆表后进度写入永远不碰快照，写放大反而低于现状；行数上千（超过 500 上限）才值得考虑 SQLite 的单行 UPDATE 与索引查询。
如果坚持"一条链只有一张表"（少一张表、少一次 join），代价是 1.6× 写放大——在 200~300 行的量级可以接受。

两张表不是复杂度回归：它们按**生命周期**拆（一次写 vs 持续写），刚好也是合并规则的分界线。

## 6. 记录创建与淘汰

- 只在「加入书架 / 开始阅读 / 开始下载」时建记录，**不能浏览详情页就入库**。
- 必须有淘汰条件，否则重演 `video_progress_v1` 的无上限问题。建议只淘汰本机：
  `shelf_at == 0 && last_read_at < now-90d && 本地无离线文件`；
  **删除本地记录 ≠ 删除云端记录**（另一台设备可能还在读）。
- **快照行不参与淘汰**，或至少与状态行分开淘汰：上游下架后这份快照就是唯一副本。

## 7. 迁移路径（建议分两步）

**第 1 步：先修 P0，不动模型。**
`video_progress_v1` 加 200 条上限、上传加 `If-Match`。纯 bug 面，与模型改造正交，先做能显著降低第二步风险。

**第 2 步：统一模型，本地仍用 prefs（拆表），同步载荷仍导出 JSON。**
- `SyncSnapshot.currentSchema` 从 1 升到 2。注意 [sync_snapshot.dart](../lib/features/sync/sync_snapshot.dart)
  的 `tryParse` 里 `schema > currentSchema` 会 return null，旧版本会报「云端同步文件格式不正确，已停止覆盖」——
  安全（不破坏数据），但意味着**两台设备需一起升级**，上线前要在设置页给这条提示。
- 老 key 保留一个版本做回滚兜底，稳定后再删。

**第 3 步（可选，仅在行数破千时）**：底层换成 sqflite，接口不变。

## 8. 结论

方向可行，且"元信息不可变"这个前提让方案实质变简单：

- 合并规则从"3 组时间戳 + 1 组无时间戳"降到"状态按时间戳、快照按 `meta_fetched_at`"，语义只有一条线；
- 同步载荷 -32%，key 数减半，派生缓存归零；
- 拆表后写放大比现状还低，**不需要 SQLite**；
- 仍然必须保留的复杂度只有一处：`shelf_at` / `shelf_removed_at` 这对时间戳（§4.3），以及合并函数的收敛性（§4.1）。
