# 历史删除（我的 → 历史）设计方案

**状态**：提案（未实现）
**日期**：2026-11-21
**入口**：我的 → 历史（单条长按 / 区块标题右侧「清空」）
**相关**：[storage-model-proposal.md](storage-model-proposal.md) §4、§6；[implementation.md](implementation.md) §11.6；`lib/core/storage/library_records.dart`、`lib/core/storage/library_db.dart`、`lib/core/storage/reading_store.dart`、`lib/features/mine/`、`lib/features/sync/cloud_sync_data_page.dart`

## 1. 目标与非目标

目标：

1. 支持**删除单条历史**与**清空全部历史**；
2. 删除要能**跨设备生效**，不会被另一台设备的旧进度在下次同步时复活；
3. 不误伤收藏：已收藏 / 在书架的书仍留在收藏里，只是不再出现在历史；
4. 不删离线缓存、不删正文，用户重新打开还能从第一章读；
5. 本地没有配置 WebDAV 时也能用；以后配置了再把这些删除事实补传上去。

非目标：

- 不在「云端数据」页直接改 `sync.json`（那是最容易把两台设备搞成互相覆盖的入口）；
- 不做「只删云端、不删本机」或「只删本机、不删云端」两种半套删除；
- 不做整份云端数据的重置/清空（需要单独的同步 epoch，见 §3 方案 E，另案）；
- 不做回收站/撤销（进度位置一旦清掉就没有第二份可恢复，见 §6.2）。

## 2. 现状

### 2.1 历史是 `library` 表的派生视图

「我的 → 历史」不是独立列表，而是从单表 `library` 查出来的：

- 取行条件：`last_read_at > 0`，且不是「移出书架后没再读」的墓碑；
- 按 `last_read_at DESC` 排，页面只展示前 3 条（`mineHistoryLimit = 3`），
  页头显示总数（`historyCount()`）；
- 小说与短剧同表，`type` 区分。

所以「删除历史」本质上就是**把一条行的进度组清掉**，而不是删某个列表项。

### 2.2 已经有一套「进度删除墓碑」

`LibraryRecord.progressPrunedAt` 不是新东西，它现在是**自动淘汰**用的：

- 纯进度行超过 `libraryLimit = 500` 时，`LibraryDb.prune` 把最旧的行清成
  `last_read_at = 0`、进度列清空、`progress_pruned_at = now`；
- 合并没有删行，而是靠 `progressPrunedAt` 压制更旧的进度：
  `last_read_at > 对方 progressPrunedAt` 才算有效进度；
- 因此淘汰事实能同步出去，远端旧进度不会把行补回来；之后又读过
  （`lastReadAt > progressPrunedAt`）会正常复活。

**这和「手动删除历史」要的语义完全一致**：删除是一个带时间戳的事实，不是一次行删除。
差别只有两点：

1. 自动淘汰只碰**不在架、没有墓碑**的行；手动删除要覆盖**在架**的行；
2. 自动淘汰会清掉快照（书名/封面）；手动删除在架的行必须**保留快照**，
   否则收藏卡片会变成「未命名作品」+ 空封面。

### 2.3 顺带发现的既有 bug：被淘汰后再加入书架会丢快照

`LibraryRecord.normalized()` 的第一个分支是：

```dart
if (progressPrunedAt > 0 && lastReadAt == 0) {
  return copyWith(title: '', cover: '', metaFetchedAt: 0, ...);
}
```

它没有判断 `onShelf`。于是：

1. 一本书被自动淘汰（`progressPrunedAt > 0`，标题已清空）；
2. 用户从推荐/详情页把它加入书架：`_addToShelf` 会把 title/cover 写回去；
3. `LibraryDb.write` 再调 `normalized()`，又因为 `progressPrunedAt > 0 &&
   lastReadAt == 0` 把标题、封面、`metaFetchedAt` 清掉。

结果是收藏里出现一本「未命名作品」、没有封面，直到用户重新读一次才恢复。
这个问题和「删除历史」直接相关：删除历史会产生大量 `progressPrunedAt > 0` 的行，
其中就包括在架的行，必须先把 `normalized()` 的边界修对。

## 3. 方案对比

| 方案 | 做法 | 结果 | 结论 |
|---|---|---|---|
| A. 直接删行 | 从 `library` 删掉历史行 | 本机干净；远端旧进度下次同步把行补回来，删除只是「本机暂时看不见」 | 不可行 |
| B. 本机忽略表 | 另存一份「已删 key」，查询时过滤 | 不同步；换机/另一台设备照样能看见；云端数据也对不上 | 不可行 |
| C. 复用 `progressPrunedAt` | 清进度 + 写删除时间，行保留 | 语义与自动淘汰相同；合并逻辑已经现成；能跨设备收敛 | **推荐** |
| D. 新字段 `historyClearedAt` | 加一列/一个 JSON 字段 | 旧客户端不认识：它照常上传旧进度、丢掉新字段，两台设备会反复互相覆盖（见 §8.2） | 不推荐 |
| E. 云端 epoch 重置 | 升 epoch、用空文件覆盖 | 能真正清空所有设备，但要求所有客户端认识 epoch，属于另一个大功能 | 另案 |

方案 C 的核心观点：**删除历史 = 写一个「截至 T 时，这条进度作废」的墓碑**，
和书架删除用 `shelfRemovedAt` 是同一个思路，不引入第二套删除机制。

## 4. 数据与合并

### 4.1 删除时改哪些字段

以一条历史记录 `r` 为例，删除操作写入 `r'`：

| 字段 | 删除后的值 | 原因 |
|---|---|---|
| `last_read_at` | `0` | 历史查询 `last_read_at > 0` 直接过滤掉 |
| `progress_ref` / `progress_index` / `progress_sub` | `''` / `0` / `0` | 不保留「读到第几章/第几集」 |
| `progress_pruned_at` | `now`（一次删除共用一个时间戳） | 删除墓碑；合并时压制更旧的进度 |
| `shelf_at` / `shelf_removed_at` | 不变 | 收藏 / 移出收藏是另一条时间线 |
| `title` / `author` / `cover` / `intro` / `episode_count` / `color_dominate` / `meta_fetched_at` | **在架时保留**；不在架时清空 | 收藏卡片还要用快照；不在架的行不再展示，清空可把同步载荷从 ~370 B 压到 ~60 B |

「在架时保留」意味着 `normalized()` 要加条件：

```dart
// 进度被淘汰 / 历史被删除，且这次删除不是「在架条目」时才瘦身快照。
// 在架条目清掉 title/cover 会让收藏变成「未命名作品」，也见 §2.3。
if (progressPrunedAt > 0 && lastReadAt == 0 && !onShelf) {
  return copyWith(
    title: '', author: '', cover: '', intro: '', episodeCount: 0,
    colorDominate: '', metaFetchedAt: 0,
    progressRef: '', progressIndex: 0, progressSub: 0,
  );
}
```

注意 `progressRef/index/sub` 在删除时已经显式清零；`normalized()` 不用替调用方清进度，
只负责「这条行还要不要留快照」。

### 4.2 合并规则（沿用现有 `mergeLibraryRecords`）

- `progressPrunedAt = max(本地, 远端)`；
- 一条进度有效，当且仅当 `lastReadAt > 对方.progressPrunedAt`；
- 进度组整组按 `lastReadAt` 取新；
- `shelfAt` / `shelfRemovedAt` 各取 max；
- 快照整组按 `metaFetchedAt` 取新，相等取远端；
- 结果再过一次 `normalized()`。

常见时序：

| 设备 A | 设备 B | 合并结果 | 说明 |
|---|---|---|---|
| 删除（T=300） | 旧进度 T=200 | 无进度，墓碑 300 | 删除生效 |
| 删除（T=300） | 删除（T=320） | 无进度，墓碑 320 | 两端都删，取较晚 |
| 删除（T=300） | 删除后又读（T=400） | 进度 400 | 另一台之后真的读了，按设计复活 |
| 删除（T=300） | 把书加入收藏 | 在架 + 无进度 + 保留快照 | 收藏不受影响 |
| 删除（T=300）且不在架 | 远端旧快照 T=50 | 无进度、墓碑 300、快照清空 | 不在架的行不留快照 |

收敛性：`max` 与「按时间戳选一侧」都是确定性的；两端看到同一份远端数据会算出同一个结果，
不会出现「A 传一版、B 传一版」的来回覆盖（旧客户端例外，见 §8.2）。

### 4.3 与自动淘汰共用逻辑，但不共用入口

自动淘汰 `LibraryDb.prune` 的 SQL 只选：

```sql
shelf_at = 0 AND shelf_removed_at = 0 AND last_read_at > 0
```

手动删除不能复用它，因为要覆盖在架行，而且在架行不能清快照。建议在 `LibraryDb` 增加一个
明确的历史删除入口，和 `prune` 并列：

```dart
/// 新增：与 [readHistory] 同一套 `_historyWhere`，但不限条数（管理页要用全量）。
static Future<List<LibraryRecord>> readHistoryAll(
  DatabaseExecutor db, {
  LibraryType? type,
}) async { /* ... */ }

/// 把一批历史行的进度清成删除墓碑；在架行保留快照。
static Future<int> clearHistoryProgress(
  DatabaseExecutor db, {
  required int now,
  LibraryType? type,
}) async {
  final rows = await readHistoryAll(db, type: type);
  for (final row in rows) {
    await write(
      db,
      row.copyWith(
        lastReadAt: 0,
        progressRef: '',
        progressIndex: 0,
        progressSub: 0,
        progressPrunedAt: now,
      ),
    );
  }
  return rows.length;
}
```

单条删除同理，只是先按 key 读一行。历史通常在几百条量级（500 是纯进度行上限，
在架条目不计入），一次性事务内逐行写足够；不需要为它写
一条复杂的大 SQL。

### 4.4 `ReadingStore` 对外 API

```dart
/// 删除一条历史（只清进度，不动收藏）。
Future<void> deleteHistory(LibraryType type, String sourceId);

/// 清空历史；[type] 为空表示小说 + 短剧一起清。
Future<int> clearHistory({LibraryType? type});
```

两者都在一个事务里完成，完成后按类型 bump 现有的 revision：

- 小说：`recentRevision++`、`novelRevision++`；
- 短剧：`videoHistoryRevision++`、`videoRevision++`。

`mineHistoryProvider` / `mineHistoryCountProvider` 已经订阅这两个细分通道，页面会自动刷新，
不需要新增 provider。

### 4.5 重新阅读时会恢复什么

删除后从详情页/收藏页重新打开：

- `_saveProgress` 会写 `lastReadAt = now > progressPrunedAt`，历史恢复；
- 不在架的行快照已被清空，`_saveProgress` 的
  `base.title.isEmpty ? title : base.title` 会把传入的标题/封面补回来；
- 在架的行快照一直保留，不存在这个问题。

所以「删除历史」不等于「删除这本书」，也不影响离线缓存和收藏。

## 5. 同步时机

删除是一个本地事实，下一次同步（回前台/退后台/「立即同步」）会把它带上云端。
但「云端数据」页显示的是**远端快照**，刚删完还没同步时仍会看到旧记录，这是预期行为。

建议：

1. v1 不做自动同步，删除后的轻提示写明「已删除，下次同步后云端也会移除」；
2. 如果在实际使用中觉得「删完马上打开云端数据」这个场景很别扭，再考虑在删除后做 1.6s
   去抖推送（与设置同步同一套节奏），或给「云端数据」页加一个「立即同步」按钮；
3. 不要每次点删除都同步一次：单条删除 + 弱网会把操作卡住，也浪费 WebDAV 请求。

同步记录页的 diff 已经会把进度显示为 `第 N 章 → —`。如果 off-shelf 记录的标题也被清空，
还会多一条 `title: 书名 → —` 的噪音；可以在 `diffLibraryData` 里对
`progressPrunedAt` 变大且无进度的记录打一条更清楚的 `history: 已删除`，并跳过标题清空这一项。
这是可选的展示优化，不影响数据正确性。

## 6. UI

### 6.1 入口

「我的 → 历史」区块标题右侧加一个 `TextButton`：

- 文案「清空」或「清空历史」；
- 仅在 `historyCount > 0` 时显示；
- 点开二次确认，文案里带上真实条数（页面只展示 3 条，必须让用户知道删的是全部 N 条）：

> 清空历史？
> 将删除全部 N 条历史记录（含未展示的）。已收藏的书仍保留在收藏里；
> 下次同步后会同步到其他设备。
> 取消 / 清空

单条删除走长按：

- `MineHistoryList` → `RecentList` → `MineRecentTile` 增加可选的 `onLongPress`；
- 长按打开和收藏管理同款的底部弹层（`showAppBottomSheet` + `AppBottomSheet`）：
  - 「删除这条历史」（`colorScheme.error`）；
  - 可保留「查看详情 / 继续阅读」，与点击行为一致；
- 单条删除不弹二次确认，删完 1s 轻提示「已删除历史记录」。

### 6.2 不建议做的事

- 不要在历史条目的左滑里直接删：现在整块是 `InkWell`，左滑会和页面滚动、长按冲突，
  也容易误触；
- 不要给历史条目加「删除」图标按钮：历史是高频浏览区，图标会把行挤乱；
- 不要用「撤销」：进度位置已经被清零，没有第二份可恢复；单条删除本身风险低，
  清空有确认框即可。

### 6.3 空态与计数

删除后 `historyCount` 变 0，历史区块显示现有空态「还没有阅读记录，去推荐页逛逛」，
页头「历史 0 · 收藏 N」自动更新。不需要额外的「已删除」占位。

## 7. 云端数据页

「云端数据」是**只读**的远端 `sync.json` 查看器，不建议在这里做写操作。

删除历史同步上去后，`sync.json` 里会出现两类行：

1. **在架 + 已删历史**：保留 title/cover，`lastReadAt = 0`、`progressPrunedAt > 0`；
2. **不在架 + 已删历史**：只剩 `type` / `id` / `progressPrunedAt`（约 60 B）。

页面上建议这样处理：

- 给 `LibraryRecord` 加一个只读判定：

  ```dart
  bool get historyDeleted => progressPrunedAt > 0 && !hasProgress;
  ```

- `_subtitleOf` 增加「历史已删除」；在架再加「已收藏」；
- 列表默认**隐藏纯删除标记**（`historyDeleted && !onShelf`），否则清空一次历史后
  云端数据页会出现几百条「无进度」的噪音；
- 在列表标题下方补一行小字：

  > 已删除历史 N 条（只保留同步标记）

  并给一个「显示 / 隐藏」开关，让这个页面仍然能完整审计云端文件；
- 计数行改成「共 X 条 · 小说 Y · 短剧 Z」+「已删除历史 N 条」，不要把这 N 条算进
  「最多 500 个」的口径里——这个 500 是库里的纯进度行上限，不是云端总行数。

**不要**在云端数据页做「删除」按钮：删除必须落到本地 `library` 表并走合并，
直接从远端文件删行会被下一轮本地同步补回来；两个设备同时操作还会产生 412 重试和覆盖。

## 8. 兼容性、风险与边界

### 8.1 SQLite / 同步格式

- 复用 `progressPrunedAt` 列，**不需要 DB schema 升级**（当前 v3 已有该列）；
- `sync.json` 的 `schemaVersion` 仍是 3，字段集合不变；
- 旧版本客户端读到「`lastReadAt = 0` + `progressPrunedAt > 0`」会照常当作「进度被淘汰」
  处理，不需要认识新功能。

### 8.2 旧客户端的一个坑（在架条目）

旧客户端的 `normalized()` 对在架的删除行也会清快照（§2.3 的 bug）。混版时可能出现：

- 新客户端删了某本**在架**书的历史，保留 title；
- 旧客户端合并后把 title/cover 清掉并上传；
- 新客户端合并时因为自己的 `metaFetchedAt` 更大又把 title 写回并上传；
- 两边来回覆盖（sync.json 内容反复变化，表现为持续上传）。

这是**旧客户端**的 `normalized()` 造成的，新方案本身在两台新客户端之间是收敛的。处理方式：

1. **推荐**：两台设备一起升级。这是个人使用的 App，渠道（release/beta/dev）本来就分文件，
   升级成本可控；
2. 如果以后要面向混版用户：把 `schemaVersion` 升到 4，新客户端仍能读 3、但只写 4，
   旧客户端看到 4 直接停止同步并提示「请升级 App」。这等于一次 flag day，不建议为了
   一个历史删除功能单独做；
3. 不建议为了兼容旧客户端而把在架条目的删除改成「删行」或「移出收藏」，那会改变语义。

纯进度（不在架）的删除不受这个坑影响：两端都会清快照，数据一致。

### 8.3 时间戳与时钟偏差

删除用本机 `DateTime.now()` 作为墓碑时间，和现有 `lastReadAt` / `shelfRemovedAt` 一样
是 LWW。跨设备时钟偏差会让时钟快的那台「更晚删除/更晚阅读」胜出；个人多设备 + NTP
下可接受，不建议为此引入 HLC。

### 8.4 删除是「截至此刻」

删除只会压制 `lastReadAt <= 删除时间` 的旧进度。另一台设备在删除之后又读了，
条目会重新出现在历史里——这是正确行为（类似浏览器历史），不是复活 bug。
如果希望「删除后永远不再出现」，需要的是黑名单而不是历史删除，不在本方案内。

### 8.5 删除标记不会回收

删除不会新增行：只是把已有的历史行改成墓碑。因此不会像「反复加架/移出」那样
产生新的 tombstone 行；但仍会留下约 60 B/条（不在架）或约 370 B/条（在架）的标记，
直到用户重新阅读或把书移出收藏。按纯进度行 500 上限 + 在架条目量级、个人使用规模，
载荷可以接受。
安全回收需要因果稳定性（确认所有设备都同步过该 revision），和现有书架 tombstone 是同一类
问题，不在本次范围。

### 8.6 正在阅读的书

同一台设备上，用户不可能一边在阅读页一边在「我的」删除历史；不同设备上的删除按 §8.4
处理。阅读页 5s 防抖落盘已经先于 `paused` 落盘，不存在「删除后旧进度延迟写回」的竞态。

## 9. 测试计划

**存储层（`test/reading_store_sync_test.dart` 或新增 `history_delete_test.dart`）**

1. 删除单条不在架历史：历史为空；导出的行含 `progressPrunedAt`、不含 `title` / `lastReadAt`；
2. 删除单条在架历史：仍在收藏；title/cover 保留；历史为空；
3. 清空全部：历史数与页头计数归零；收藏不受影响；
4. 合并：远端旧进度被压制；远端更新进度复活；两端删除取 max；
5. 回归：被 `prune` 淘汰后再 `addToShelf`，title/cover 不丢（§2.3）；
6. 重新阅读后历史恢复，且快照补回。

**UI（`test/ui/mine_test.dart`）**

1. 历史标题右侧「清空」只在非空时出现；
2. 确认框显示真实条数；取消不删、确认后空态 + 计数更新；
3. 长按历史条目弹出菜单，点「删除这条历史」后条目消失；
4. 在架条目删除后收藏仍可见；
5. golden：`mine_shelf.png` / `mine_empty.png` 按新标题行更新。

**云端数据页（`test/ui/` 或 `cloud_sync_data_page_test.dart`）**

1. 删除标记默认隐藏，标题行显示「已删除历史 N 条」；
2. 打开「显示」后能看到墓碑行，副标题为「历史已删除」；
3. 在架 + 已删历史仍显示，并同时标「已收藏」。

## 10. 落地顺序

1. **P0（数据正确性）**：修 `normalized()` 的 `onShelf` 边界 + 回归测试；
   增加 `LibraryDb.clearHistoryProgress` 与 `ReadingStore.deleteHistory/clearHistory` + 单测。
2. **P1（可用）**：历史标题「清空」+ 长按单条删除 + 确认框 + 空态/计数；
   更新 mine 相关 golden。
3. **P2（云端可读性）**：云端数据页的「历史已删除」标记、默认过滤、计数与开关；
   可选：删除后 1.6s 去抖推送、同步记录里的「历史已删除」文案。

P0/P1 不依赖云端页面改动，可以先上；P2 是为了避免用户清空历史后打开「云端数据」看到
几百条「无进度」而以为没删干净。

## 11. 结论

- 不需要新表、新列或 `schemaVersion` 升级：`progressPrunedAt` 本来就是「进度删除时间」，
  把它从「自动淘汰专用」提升为「自动淘汰 + 用户删除历史」共用即可；
- 真正要补的是两块：**在架行保留快照**（同时修掉一个既有 bug）和**在架行的合并兼容**；
- 单条删除走长按菜单、清空走标题右侧按钮，云端数据页保持只读并给删除标记一个可折叠的出口；
- 混版旧客户端只影响在架条目的快照，推荐两台设备一起升级；如果需要长期混版，再单独做
  schema 4 / capability 协商，不要把它塞进这个功能里。
