# 设置项云同步（settings.json）

**状态**：设计完成，待实现
**入口**：设置 → 同步（随生命周期自动拉取 / 推送，不新增手动按钮）
**相关**：[implementation.md](implementation.md) §11.6、[sync-log-design.md](sync-log-design.md)、[storage-model-proposal.md](storage-model-proposal.md)

## 1. 目标与非目标

目标：

1. 主题色、深浅色、全局字重、推荐流布局、阅读排版跨设备一致（换机不用重调）。
2. 设置改动自动上传，不用记得点同步；启动或从后台回前台自动拉一次。
3. 与书架 / 收藏 / 进度的 `sync.json` **完全解耦**：互不影响、互不阻塞、互不覆盖。

非目标：

- **不做 `ConfigProvider` 重构**。设置仍由各 feature 的 `NotifierProvider` 持有（见 §2），同步层只要求它们各自暴露 `capture()` / `applyRemote()`。
- 不把设置塞进 `sync.json`（理由见 §3）。
- 不做逐字段合并、不做冲突提示：整包 LWW（last-write-wins）已经够用。
- 不同步设备相关偏好（播放倍速、下载清晰度，见 §7）。
- 不在阅读页 / 播放页内应用远端排版（见 §5「沉浸页挡板」）。

## 2. 现状

设置项当前由 **8 个 provider、17 个 `shared_preferences` key** 分散持有，没有统一对象：

| 设置 | provider | prefs key |
|---|---|---|
| 主题色 | `themeSeedProvider` | `app_seed_color_v1` |
| 自定义色（圆点记忆） | `customThemeSeedProvider` | `app_custom_seed_color_v1` |
| 深浅色模式 | `themeModeProvider` | `app_theme_mode_v1` |
| 全局字重（仅 Android 生效） | `appFontWeightProvider` | `app_font_weight_v1` |
| 推荐流布局 | `recommendLayoutProvider` | `home_recommend_layout_v1` |
| 阅读排版（10 项） | `readerSettingsProvider` | `reader_*_v1` × 10 |
| 播放倍速 | `playbackSpeedProvider` | `video_playback_speed_v1` |
| 下载清晰度 | `videoDownloadQualityProvider` | `video_download_quality_v1` |

现有云同步只覆盖 `library` 表：`ReadingStore.exportSyncData()` 产出 `{'items': [...]}`
（`lib/core/storage/reading_store.dart:370`），文件是
`novel-playlet/<profile>/sync.json`，`schemaVersion = 3`
（`lib/features/sync/sync_snapshot.dart:24`）。**设置一个字段都不在载荷里。**

## 3. 为什么用独立 `settings.json` 而不是给 `sync.json` 加字段

给 `data` 加一个 `settings` key，解析层确实是免费的：`tryParse` 对 `data` 是任意键都收的
`Map`（`sync_snapshot.dart:31`、`:59`），`applySyncData` 只读 `data['items']`
（`reading_store.dart:391`）。但「合并」那一步是**按类型模型重建**而不是保留未知字段：

```dart
// lib/features/sync/sync_service.dart:183
final mergedData = await store.exportSyncData();   // 只产出 {'items': [...]}
```

于是**任何还在跑旧版本（`schemaVersion = 3`，如 1.0.2）的设备**会：解析成功 → 只合并 `items`
→ `mergedData` 不含 `settings` → PUT 把整份文件写回去，**设置被静默删除**。同步日志也看不出来
（`diffLibraryData` 只索引 `items`，`sync_log.dart:280`）。这正好违反 `sync_snapshot.dart`
注释里写明的「绝不静默清空远端」。

| 方案 | schema | 旧客户端行为 | 迁移 | 结论 |
|---|---|---|---|---|
| `data.settings` 加字段 | 不动 | 解析成功，**静默抹掉**设置 | 无 | 风险高、难察觉 |
| bump 到 4 | 3 → 4 | `tryParse` 拒绝，报「格式不正确，已停止覆盖」，**连书和进度一起停** | 要写 v3 兼容读取 | 显式失败但停摆 |
| 独立 `settings.json` | 完全不涉及 | 不知道这个文件存在，**永不改写** | 无 | ✅ 采用 |

`syncProfile` 已把 release / beta / dev 分到不同目录（`sync_meta.dart:13`），设置文件跟着走，
跨渠道不会互踩。

## 4. 文件格式

路径：`novel-playlet/<profile>/settings.json`

```json
{
  "v": 1,
  "deviceId": "…",
  "updatedAt": 1763512345678,
  "settings": {
    "theme": { "seed": 4280391411, "mode": 0, "customSeed": 4286473922 },
    "fontWeight": 400,
    "feed": { "layout": 0 },
    "reader": {
      "fontSize": 21,
      "lineHeight": 1.8,
      "fontWeight": 400,
      "followGlobalFontWeight": true,
      "paper": "parchment",
      "dayPaper": "parchment",
      "showBubbles": true,
      "showDialogueHighlight": true,
      "dialogueHighlightColor": 4294954319,
      "dialogueHighlightStyle": "marker"
    }
  }
}
```

约定：

- `v` 是这个文件自己的版本号，与 `sync.json` 的 `schemaVersion` 无关；以后改设置结构只升它。
- 枚举一律存 `name` 而不是下标（阅读纸色 / 对话高亮样式），避免以后插入新值错位。
- 解析必须严格：`v` 不认识、`settings` 不是 Map、`updatedAt` 不是 int 时**整份忽略**，
  不改本地、不清远端；坏文件只记日志，等下次同步覆盖。
- 读取时对每个字段做 clamp / 白名单校验（字号 15–30、行距 1.3–2.0、字重整百档、
  倍速白名单等），非法值回落默认，不能把脏值写进 provider。

本地元数据单独一份 `settings_sync_meta_v1`：

```
{ remoteEtag, localHash, lastRemoteUpdatedAt, lastSyncAt }
```

与 `webdav_sync_meta_v1` 互不影响。

## 5. 同步时机

| 时机 | 动作 | 说明 |
|---|---|---|
| 冷启动、首帧后 | 拉取 | 与 `sync.json` 的库同步并行发起，互不阻塞 |
| `resumed` | 拉取 | 「从后台回来」；现有 `sync_lifecycle.dart:33` 已监听，加一个并行分支 |
| `paused` | 推送（仅脏） | 退后台前把改动推上去，避免被系统杀进程丢改动 |
| 设置变更后 1.5–2s | 推送（仅脏） | 去抖，覆盖设置页之外的所有入口（阅读器排版、播放倍速） |
| 离开设置页 | 推送（仅脏） | 兜底，不是唯一触发点 |
| 手动「立即同步」 | 待定 | 现有按钮只跑库同步；是否一起跑见 §10 |

### 沉浸页挡板

拉取可以在任何时刻发起，但**应用（apply）前要判断当前有没有沉浸页**：
阅读页、播放页、设置页压栈时不 apply，只更新 `remoteEtag` 与 `lastSyncAt`，
**不推进 `lastRemoteUpdatedAt`**，这样下次 `resumed` 还会判定「远端比已应用的新」并重试。

理由：

- 阅读中回填字号 / 行距会触发整章重排，可能丢掉阅读位置；
- 播放中回填倍速会改当前播放速度；
- 设置页正在被操作时回填，会让开关在指尖下跳动。

判断方式（项目没有路由表，`toRoute()` 全是匿名 `MaterialPageRoute`）：
`reader_page.dart:187/194`、`video_player_page.dart:171/183`、设置页进入/退出时维护一个
`immersivePageProvider` 计数，`idle == 0` 才允许 apply。详情页 / 搜索页 / 缓存中心不算沉浸页，
它们不受排版影响，允许拉取。

**推送不受页面限制**：写网络不影响 UI，阅读器里调完字号一样会去抖上传。

## 6. 冲突与一致性

整包 LWW，规则只有四条：

1. **本地脏且比远端新 → 推本地**；本地脏但比远端旧 → 应用远端（远端赢）。
2. **本地不脏且远端 `updatedAt > lastRemoteUpdatedAt` → 应用远端**；否则什么都不做。
3. **apply 绝不能置脏**。回填时置一个 `_applyingRemote` 标志，屏蔽 setter 的 `markDirty`，
   并直接写 prefs。否则 pull → 写盘 → 脏 → push → 改 `updatedAt` → 另一台再 pull，
   两台设备会无限乒乓上传。
4. **推送带 `If-Match: <etag>`**，收到 412 就重新拉一次、按规则 1 重判，再决定推还是应用。

已知限制：LWW 依赖设备时钟。缓解办法是 apply 远端时把本地 `updatedAt` 回写成远端值，
让两台设备的基准时间收敛；时钟差很大时仍可能判错，但设置类数据可接受。

单飞锁：设置同步自己一个 in-flight 标志，不复用 `sync_status.dart:40` 的全局
`isSyncing`——那会把库同步和设置同步串成互相阻塞；两个文件互不依赖，应该并行。

## 7. 同步白名单

| 分组 | 字段 | 同步 | 理由 |
|---|---|---|---|
| theme | seed / mode / customSeed | ✅ | 跨设备观感一致 |
| font | 全局字重 | ✅ | 仅 Android 生效，iOS 拉到无害 |
| feed | 布局（双列 / 三列） | ✅ | 观感一致 |
| reader | 10 项排版 | ✅ | 核心场景 |
| video | 播放倍速 | ❌ | 设备习惯 |
| video | 下载清晰度 | ❌ | 与设备存储 / 流量相关 |

`followGlobalFontWeight` 随阅读设置一起同步；iOS 上全局字重恒为 400，跟随与否观感一致，无需特判。

## 8. 改动清单

| # | 位置 | 改动 | 量级 |
|---|---|---|---|
| 1 | 新增 `lib/features/sync/settings_sync_snapshot.dart` | 文件结构、严格解析、字段校验 | ~120 行 |
| 2 | 新增 `lib/features/sync/settings_sync_service.dart` | 拉 / 推 / 条件请求 / LWW / 单飞 | ~220 行 |
| 3 | 新增 `lib/features/sync/settings_sync_coordinator.dart` | 脏标记、去抖、`flush()`、`_applyingRemote` | ~90 行 |
| 4 | `lib/features/sync/sync_meta.dart` | 新增 `settings_sync_meta_v1` | ~40 行 |
| 5 | 6 个设置 controller | `capture()` / `applyRemote()` / `markDirty()` | ~150 行 |
| 6 | 新增 `immersivePageProvider` + 阅读页 / 播放页 / 设置页挂点 | idle 判断 | ~30 行 |
| 7 | `lib/features/sync/sync_lifecycle.dart` | resumed 拉取、paused 推送 | ~30 行 |
| 8 | `lib/features/mine/mine_page.dart:67` | 设置页 pop 后 flush | ~5 行 |
| 9 | `lib/features/sync/widgets/webdav_sync_card.dart` | 「设置同步 · 已同步 / 待上传 / 失败」一行（可选） | ~40 行 |
| 10 | 新增 `test/settings_sync_test.dart` | 往返、LWW、脏不乒乓、412、未知 `v`、离线重试 | ~200 行 |
| 11 | `docs/implementation.md` §11.6、`CONTRACTS.md` | 补 `settings.json` 与白名单 | ~20 行 |

**明确不做**：`ConfigProvider` 重构、`sync.json` 改动（0 行）、阅读器重排 / 阅读位置恢复、
云端数据页展示设置（它读的是 `sync.json`，要展示得再发一次请求，MVP 不做）。

预计 **0.8–1.2 人日**。

## 9. 实现要点 / 坑

1. **`_userChanged` 守卫要绕过**。每个 controller 都有「磁盘值不能覆盖用户刚改的值」的保护
   （启动回填用），`applyRemote()` 必须显式设置状态，不能复用 `_restore()`。
2. **不能用 `ref.invalidate` 应用设置**。`main.dart:38` 的四个 override 在构造时捕获了
   启动那一刻的值，`invalidate` 重建仍拿旧值。必须直接调 controller 的 `applyRemote()`。
3. **阅读设置要等恢复完成**。`ReaderSettingsController.isRestored` / `restoreFuture`
   （`reader_settings.dart:187-190`）没完成时，state 还是默认值，此时 apply 远端会覆盖掉
   本机已恢复的值（随后被 `_restore()` 又覆盖回来，产生闪烁）。
4. **prefs 按 key 写，部分失败要能收敛**。写失败只影响下次启动，不能让同步整体失败；
   脏标记保留，下轮重试。
5. **设置项继续增长时再考虑 `AppConfig`**。现在 `capture/apply` 是每加一项改两处；
   超过 20 项或要做「导出配置文件」时，再评估把 8 个 provider 收编成单一不可变对象。
   它是可选优化，不是本次同步的前置条件。

## 10. 待定问题

1. 白名单是否按 §7 执行（倍速、下载清晰度不同步）。
2. 设置页是否也算沉浸页（本文按「算」写：操作时不回填）。
3. 详情 / 搜索 / 缓存中心是否允许拉取（本文按「允许」写）。
4. 手动「立即同步」是否同时跑设置同步。
5. 设置同步是否进「同步记录」页（要的话给 `SyncLogRun` 加 `scope` 字段）。
