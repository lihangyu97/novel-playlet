# WebDAV 同步日志

**状态**：设计完成，待实现（依赖单表 `library` 模型，见 [storage-model-proposal.md](storage-model-proposal.md)）
**入口**：设置 → WebDAV 配置弹层 → 「同步记录」

## 1. 目标与非目标

目标：同步出问题时能自己回答三个问题，不用开日志或抓包。

1. 上次同步成功了吗？失败在哪一步？
2. 这次上传 / 拉取了几条、revision 从几到几、云端那份是谁写的？
3. 具体是哪本书、哪个字段、从什么变成了什么？

非目标：

- **日志不参与云同步**。它是设备本地诊断数据，进 `sync.json` 只会放大载荷、两台设备互相覆盖。
- 不做错误上报 / 远程采集。
- 不记录 WebDAV 凭据、完整 URL、密码（只记 `profile` 与 host）。

## 2. 为什么"同步了什么"几乎是免费的

看 `lib/features/sync/sync_service.dart` 的 `sync()`，一次同步在内存里**同时存在三份快照**：

```dart
final localData  = await store.exportSyncData();      // 合并前
if (remote != null) await store.applySyncData(remote.data);
final mergedData = await store.exportSyncData();      // 合并后 = 本地最终态
// remote.data                                          // 云端那份
```

于是两个方向的变更清单可以纯粹在 service 层算出来：

| 想知道 | 算法 | 含义 |
|---|---|---|
| 拉取到什么 | `diff(localData, mergedData)` | 本地被云端改成了什么样 |
| 上传了什么 | `diff(remote.data, mergedData)` | 合并结果和云端差在哪 |

`shouldUpload` 现在就是 `remoteJson != mergedJson`——**同一个比较，只是把差异拆成条目**。

结论：**不需要改 `applySyncData` 的签名，也不需要存储层配合**。日志逻辑全部落在
`sync_service.dart` + 一个新的 `sync_log.dart`，diff 只是一个纯函数。

## 3. 数据模型

### 3.1 内存模型

```dart
enum SyncTrigger { manual, lifecycle, config }

enum SyncOutcome { success, failed, skipped }

class SyncLogRun {
  final int at;                 // 开始时间（本机毫秒）
  final int durationMs;
  final SyncOutcome outcome;
  final SyncTrigger trigger;
  final String? phase;          // 失败阶段：config / dir / get / parse / merge / put
  final int revBefore;          // 本地记录的 lastRevision（0 = 首次）
  final int revAfter;
  final bool uploaded;
  final String remoteDeviceId;  // 云端快照的 deviceId；空 = 云端无文件
  final int remoteUpdatedAt;    // 云端快照生成时间
  final int pulledTotal;        // 明细截断前的真实条数
  final int pushedTotal;
  final List<SyncLogChange> pulled;
  final List<SyncLogChange> pushed;
  final String? error;          // 面向用户的文案，不含 URL / 密码
}

class SyncLogChange {
  final String key;      // 'novel/123'（与 LibraryRecord.key 一致）
  final String type;     // 'novel' | 'playlet'
  final String title;    // 可能为空（墓碑行被 normalized 清过快照）
  final List<SyncLogField> fields;
}

class SyncLogField {
  final String field;    // 'progress' | 'shelf' | 'title' | 'cover' | 'author' | 'intro' | 'episodeCount'
  final String before;   // 已渲染文案：'第 12 章 · 第 3 段' / '在架' / '移出'
  final String after;
}
```

`before` / `after` 存**已渲染的文案**而不是结构化值，是为了让页面不需要再懂小说章节/短剧集数的区别。代价是文案冻结在写入时刻，改文案不会影响历史记录——对诊断日志可以接受。

### 3.2 磁盘格式

单文件 `<appSupport>/sync-log.json`，保留最近 **50 次**（或 30 天，先到为准）：

```json
{
  "v": 1,
  "runs": [
    {
      "at": 1763266800000,
      "ms": 840,
      "ok": true,
      "trig": "lifecycle",
      "rev": [12, 15],
      "up": true,
      "dev": "aB3x9Q",
      "rup": 1763266794000,
      "pull": [
        {
          "k": "novel/123",
          "ty": "novel",
          "t": "剑来",
          "f": [{ "f": "progress", "b": "第 12 章 · 第 3 段", "a": "第 15 章 · 第 1 段" }]
        }
      ],
      "push": [],
      "pt": 5,
      "qt": 3,
      "err": null
    }
  ]
}
```

单条 20 个明细约 3~6 KB，50 次上限约 300 KB。

### 3.3 字段 → 中文标签

| 组 | `LibraryRecord` 字段 | 标签 | 文案示例 |
|---|---|---|---|
| 快照 | `title` / `author` / `cover` / `intro` / `episodeCount` | 书名 / 作者 / 封面 / 简介 / 集数 | `旧值 → 新值`；封面对比只说"更换"，不贴 URL |
| 进度 | `lastReadAt` + `progressRef` + `progressIndex` + `progressSub` | 进度 | 小说 `第 12 章 · 第 3 段`；短剧 `第 8 集` |
| 书架 | `shelfAt` / `shelfRemovedAt` | 收藏 | `加入` / `移出` |

`lastReadAt` 只作为"进度变了"的判据，本身不进文案（时间戳对用户没信息量）。
`shelfRemovedAt > shelfAt`（墓碑）渲染成 `移出`，而不是"收藏时间变化"。

## 4. diff 算法

三份快照都是 `{'items': [LibraryRecord.toJson()]}`。按 `'$type/$id'` 建索引后逐 key 归并：

```
keys = union(local, remote)
for key in keys:
  l = local[key], r = remote[key]
  merged = mergedData[key]      // 已经在库里，直接读，不必重算合并
  if l == merged: 无本地变化
  else: pulled.add(diff(l, merged))
  if r == merged: 无上传差异
  else: pushed.add(diff(r, merged))
```

四类变化：

| 场景 | `l` | `r` | 归类 |
|---|---|---|---|
| 只有远端有 | 缺 | 有 | `pulled`：新增到本机 |
| 只有本地有 | 有 | 缺 | `pushed`：上传（首次同步时可能有几百条） |
| 两边都有、字段不同 | 有 | 有 | 两侧各自算 diff，可能同时出现在 `pull` 和 `push`（不同字段各归一边） |
| 完全一致 | — | — | 不记 |

**字段级 diff 需要新增能力**：`LibraryRecord.diffFrom` 现在只返回 `bool`。要么在
`library_records.dart` 加一个 `List<LibraryField> changedFields(LibraryRecord other)`，
要么把比较逻辑放在日志层（不进 core）。倾向前者——核心模型知道自己有哪些字段，
外部重复一份字段列表迟早会漏。

**墓碑的坑**：`normalized()` 会把墓碑行的 `title` / `cover` 等清空，所以"移出收藏"
那条日志可能拿不到书名。兜底顺序：`changed.title` → 对方那份的 title → `key` 原文。
更好的做法是 diff 时把两侧记录都带进来，用 `l.title.isNotEmpty ? l.title : r.title`。

## 5. 采集点

`sync()` 拆成两层，日志不污染主流程：

```
sync(config, trigger)     → 计时 + try/catch/finally + 记 run
  └ _runSync(config)      → 现在的 1~4 步，失败直接 throw
```

| `sync_service.dart` | 事件 | 记录内容 |
|---|---|---|
| L46 `config.validate()` | `failed / phase=config` | 校验文案 |
| L49 `ensureDirectory` | `failed / phase=dir` | 409、权限问题的报错 |
| L50 `readText` | `failed / phase=get` | 网络、401/403 |
| L53~59 `tryParse`、profile 校验 | `failed / phase=parse` | 「云端同步文件格式不正确，已停止覆盖」 |
| L62~67 导出 + 合并 | — | 算两个方向的 diff |
| L79~82 `writeText` | `failed / phase=put` | 507 配额、412 |
| L84~89 `metaStore.write` | — | `revBefore → revAfter` |
| `syncNow()` 的 `isSyncing` 早退 | `skipped` | 否则排障时会误以为"没触发" |

`trigger` 需要新增参数：现在三个调用方（生命周期、卡片按钮、配置保存后）打的都是同一句
"正在同步"，日志里区分不出来。建议 `syncNow({SyncTrigger trigger = SyncTrigger.manual})`。

写日志必须 **best-effort**：整个写入包 try/catch 吞掉，日志失败绝不能让同步失败。

## 6. UI

### 6.1 入口

放在配置弹层里（用户明确要求的位置），"清除已保存配置"下面、按钮组上面：

```
┌──────────────────────────────┐
│ 服务器地址 / 账号 / 应用密码    │
│ [清除已保存配置]               │
│ ──────────────────────────── │
│ 同步记录                 12 › │  ← 新增
│ [测试连接]        [保存]       │
└──────────────────────────────┘
```

替代位置：设置页 WebDAV 卡片上再加一个图标。略挤，且卡片已经有两个动作，倾向前者。

### 6.2 列表

按天分组，倒序：

```
今天
  20:14  ✓  ↑3 ↓5   r12 → r15        0.8s
  18:02  ✓  无变化   r12 → r12        0.3s
  09:31  !  拉取失败                   1.2s
         云端同步文件格式不正确，已停止覆盖
昨天
  23:40  ✓  ↑0 ↓12  r10 → r12        1.1s
```

- 左侧：时间 + 结果图标（成功绿 ✓ / 失败红 ! / 跳过灰 —）
- 中间：`↑上传条数 ↓拉取条数`，都为 0 时显示 `无变化`
- 右侧：`r12 → r15` 与耗时
- 失败行第二行显示错误文案

### 6.3 展开详情

```
拉取到本机（5）
  [小说] 剑来        进度：第 12 章 · 第 3 段 → 第 15 章 · 第 1 段
  [短剧] 春日暖阳    进度：第 8 集 → 第 12 集
  [小说] 雪中悍刀行   收藏：在架 → 移出
上传到云端（3）
  [小说] 长夜难明    进度：第 2 章 → 第 7 章
```

类型徽标复用「我的」页那套绿（小说）/ 橙（短剧）。

### 6.4 其他

- 顶部一行状态：`云端 r15 · 另一台设备 20:13 写入`
- 底部「清空记录」，带二次确认
- 空态：「还没有同步记录」

## 7. 边界与坑

1. **首次同步会把整库算成"上传"**：几百条明细。必须截断（只留前 20 条 + 「另有 N 条」），
   用 `pulledTotal` / `pushedTotal` 记真实数量。
2. **日志写入失败不能影响同步**：best-effort，吞异常。
3. **`inactive` → `paused` 会连发两次同步**，配置保存后还会再一次。短时间可能出三条记录——
   靠 `trigger` 区分、UI 如实展示，或加"同 trigger 2s 内合并"。
4. **别记完整 URL / 密码**。只记 `profile`（dev/beta/release）与 host。
5. **时间用云端快照的 `updatedAt`**，跨设备排查时"云端那份是几点生成的"比"我几点拉的"更有用。
6. **`skipped` 也是结果**：`isSyncing` 期间重复调用返回 `null`，不留痕迹会误导排障。
7. **`id` 与标题分开存**：标题会变，日志要能表达"书名从 A 改成 B"。墓碑行标题为空，
   按 §4 的兜底顺序处理。
8. **进度裁剪不在日志里**：`prune`（`libraryLimit = 500`）在 `applySyncData` 内部直接删行，
   不产生 diff，所以"某本书从历史里消失"这件事同步日志看不到。要不要单独记，需要单独决定。
9. **磁盘占用与并发**：50 条上限 + 原子写（复用 `offline_paths.dart` 的 `writeJsonAtomically`）。
   同步有 `isSyncing` 保护，不会并发写同一个文件。
10. **为什么不放进 `library.db`**：那个库的契约是"删了等于清空书架"，日志混进去会让语义变模糊；
    而且它会被 `exportSyncData()` 整个导出——日志必须天然排除在同步载荷之外。也不进 prefs：
    prefs 是整块读写，50 条每次全量重写。

## 8. 落地顺序

| 阶段 | 内容 | 量级 |
|---|---|---|
| P0 | run 级记录（时间 / 结果 / 失败阶段 / ↑↓条数 / revision / 耗时）+ 列表页 + 入口 | ~300 行 |
| P1 | 双向 diff 明细（含 `changedFields`）+ 展开态 | ~200 行 |
| P2 | 清空、按天分组、`trigger` 区分、截断文案 | ~80 行 |

P0 不需要任何 diff 能力，能先回答"昨天到底同步成功没有"这个最高频的问题。

## 9. 待定

- `trigger` 参数要不要顺便把 `SyncLifecycle` 的两次触发合并成一次（`inactive` 时不同步、
  `paused` 时才同步），从源头减少重复记录。
- 进度裁剪（`prune`）要不要在日志里留一条"清理了 N 条"。
- 是否允许导出日志文件用于排障（会含书单标题，需要明确提示）。
