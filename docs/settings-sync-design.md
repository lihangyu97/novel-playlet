# 设置项云同步（settings.json）

**状态**：已实现（2026-11-18）
**入口**：设置 → 同步（随生命周期自动拉取 / 推送，不新增手动按钮）
**相关**：[implementation.md](implementation.md) §11.6、[sync-log-design.md](sync-log-design.md)、[storage-model-proposal.md](storage-model-proposal.md)

## 1. 目标与非目标

目标：

1. 主题色、深浅色、全局字重、推荐流布局、阅读排版跨设备一致（换机不用重调）。
2. 设置改动自动上传，不用记得点同步；启动或从后台回前台自动拉一次。
3. 与书架 / 收藏 / 进度的 `sync.json` **完全解耦**：互不影响、互不阻塞、互不覆盖。

非目标：

- **不做单一 `AppConfig` / `ConfigProvider` 重构**。设置仍由各 feature 的 `NotifierProvider` 持有（见 §2）；同步层通过 `SettingsSection` 注册表做 capture / apply / 校验，新增设置只加一条 section 字段，不引入 god object。
- 不把设置塞进 `sync.json`（理由见 §3）。
- 不做逐字段合并、不做冲突提示：整包 LWW（last-write-wins）已经够用。
- 不同步设备相关偏好（播放倍速、下载清晰度，见 §7）。
- 不在阅读页 / 播放页内应用远端排版（见 §5「沉浸页挡板」）。

## 2. 现状

设置项当前由 **9 个 provider、18 个 `shared_preferences` key** 分散持有，没有统一对象：

| 设置 | provider | prefs key |
|---|---|---|
| 主题色 | `themeSeedProvider` | `app_seed_color_v1` |
| 自定义色（圆点记忆） | `customThemeSeedProvider` | `app_custom_seed_color_v1` |
| 深浅色模式 | `themeModeProvider` | `app_theme_mode_v1` |
| 全局字重（仅 Android 生效） | `appFontWeightProvider` | `app_font_weight_v1` |
| 推荐流布局 | `recommendLayoutProvider` | `home_recommend_layout_v1` |
| 「我的」页模块顺序 | `mineSectionOrderProvider` | `mine_section_order_v1` |
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
    "theme": { "seed": 4280391411, "mode": "system", "customSeed": 4286473922 },
    "fontWeight": 400,
    "feed": { "layout": "two" },
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
    },
    "mine": { "sections": ["pins", "collection", "history"] }
  }
}
```

约定：

- `v` 是这个文件自己的版本号，与 `sync.json` 的 `schemaVersion` 无关；以后改设置结构只升它。
- 枚举一律存 `name` 而不是下标（阅读纸色 / 对话高亮样式），避免以后插入新值错位。
- 解析必须严格：`settings` 不是 Map、`updatedAt` 不是 int、`deviceId` 为空时整份判坏；
  **`v` 不认识时必须停止同步**（不拉不推），绝不能把 v1 写回去覆盖更高版本；状态栏提示
  “需要升级 App”。坏文件只记日志，不清远端。
- 读取时对每个字段做 clamp / 白名单校验（字号 15–30、行距 1.3–2.0、字重整百档、
  倍速白名单等），非法值回落默认，不能把脏值写进 provider。

本地元数据单独一份 `settings_sync_meta_v1`：

```
{ deviceId, remoteEtag, remoteHash, localHash, lastRemoteUpdatedAt, lastSyncAt }
```

与 `webdav_sync_meta_v1` 互不影响。另外用独立 key `settings_local_updated_at_v1`
保存「本地最后一次变更时间」：设置改动时只写这一项，不和网络层的 meta 抢
read-modify-write；重启后仍然能做 LWW。

## 5. 同步时机

| 时机 | 动作 | 说明 |
|---|---|---|
| 冷启动、首帧后 | 拉取 | 与 `sync.json` 的库同步并行发起，互不阻塞 |
| `resumed` | 拉取 | 「从后台回来」；现有 `sync_lifecycle.dart:33` 已监听，加一个并行分支 |
| `paused` | 推送（仅脏） | 退后台前把改动推上去，避免被系统杀进程丢改动 |
| 设置变更后 1.5–2s | 推送（仅脏） | 去抖，覆盖设置页之外的所有入口（阅读器排版、播放倍速） |
| 离开设置页 | 推送（仅脏） | 兜底，不是唯一触发点 |
| 手动「立即同步」 | 书库 + 设置并行 | 一次点击同步两件东西，避免“只同步了一半” |

### 沉浸页挡板

拉取可以在任何时刻发起，但**应用（apply）前要判断当前有没有沉浸页**：
阅读页、播放页、设置页压栈时不 apply，只更新 `remoteEtag` 与 `lastSyncAt`，
**不推进 `lastRemoteUpdatedAt`**，这样离开沉浸页或下次 `resumed` 还会判定「远端比已应用的新」并重试。

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

1. **本地脏且 `localUpdatedAt > remote.updatedAt` → 推本地**；否则远端赢（时间相同也远端赢）。
2. **本地不脏且远端 `updatedAt > lastRemoteUpdatedAt`（或时间相同但 hash 不同）→ 应用远端**；
   否则什么都不做。
3. **apply 绝不能置脏**。回填时置一个 `_applyingRemote` 标志，屏蔽监听器的脏标记，
   并直接写 prefs。否则 pull → 写盘 → 脏 → push → 改 `updatedAt` → 另一台再 pull，
   两台设备会无限乒乓上传。
4. **推送带 `If-Match: <etag>`**，收到 412 就重新拉一次、按规则 1 重判，再决定推还是应用。
5. **apply 被沉浸页挡住时不推进 `lastRemoteUpdatedAt`**，下次 resumed 仍会判定远端较新并重试。

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
| mine | 「我的」页模块顺序 | ✅ | 观感一致；脏值补齐成完整排列 |
| reader | 10 项排版 | ✅ | 核心场景 |
| video | 播放倍速 | ❌ | 设备习惯 |
| video | 下载清晰度 | ❌ | 与设备存储 / 流量相关 |

`followGlobalFontWeight` 随阅读设置一起同步；iOS 上全局字重恒为 400，跟随与否观感一致，无需特判。

## 8. 改动清单

| # | 位置 | 改动 | 状态 |
|---|---|---|---|
| 1 | `lib/features/sync/settings_sync_snapshot.dart` | 文件结构、严格解析、canonical hash、未知 `v` | ✅ |
| 2 | `lib/features/sync/settings_sync_meta.dart` | 独立 meta + 本地时间戳 | ✅ |
| 3 | `lib/features/sync/settings_sections.dart` | `SettingsSection` 注册表：主题 / 全局字重 / 推荐布局 / 阅读排版 | ✅ |
| 4 | `lib/features/sync/settings_sync_service.dart` | 拉 / 推 / 条件请求 / LWW / 412 / 未知 v 停止 | ✅ |
| 5 | `lib/features/sync/settings_sync_coordinator.dart` | 脏标记、去抖、单飞、`_applyingRemote`、状态 | ✅ |
| 6 | 6 个设置 controller | `restoreFuture` / `applyRemote` | ✅ |
| 7 | `lib/app/immersive_page.dart` + 路由 | 阅读页 / 播放页 / 设置页挡板 | ✅ |
| 8 | `sync_lifecycle.dart` / `webdav_sync_card.dart` | resumed/paused、手动同步两者并行 | ✅ |
| 9 | `sync_log.dart` / `sync_log_page.dart` | `scope=settings`，设置同步也进「同步记录」 | ✅ |
| 10 | `test/settings_sync_test.dart` 等 | 往返、LWW、412、未知 v、沉浸页、sync log | ✅ |
| 11 | `docs/implementation.md` / `CONTRACTS.md` | 补 `settings.json`、白名单、测试 | ✅ |

**明确不做**：单一 `AppConfig` / `ConfigProvider` 重构、`sync.json` 改动（0 行）、
阅读器重排 / 阅读位置恢复、云端数据页展示设置（它读的是 `sync.json`，要展示得再发一次请求）。

实际实现约 1 个工作日：同步服务 + 注册表 + 挡板 + 同步记录 + 测试。

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
5. **设置项继续增长时先加 Section，不要直接上 `AppConfig`**。本次已用
   `SettingsSection` 注册表把 capture/apply/校验收口，新增设置优先加已有 section 的字段；
   超过 25–30 项、或要做导入导出 / 重置全部 / 设置搜索 / 多 profile 时，再评估把 8 个
   provider 收编成单一不可变对象。它是可选优化，不是本次同步的前置条件。

## 10. 已定问题

1. **白名单**：按 §7 执行，倍速与下载清晰度不同步。
2. **设置页算沉浸页**：操作时不回填；进入/退出由路由上的 `ImmersivePageTracker` 计数。
3. **详情 / 搜索 / 缓存中心允许拉取**：它们不受排版回填影响。
4. **手动「立即同步」同时跑书架 + 设置**，两者并行，互不阻塞。
5. **设置同步进「同步记录」**：`SyncLogRun.scope = settings`，列表行用「设置」标记；
   无变化不记录，避免每次前后台都刷一条。

## 11. 实现记录（2026-11-18）

- 新增文件：`settings_sync_snapshot.dart`（结构/严格解析/hash）、`settings_sync_meta.dart`
  （独立 meta + `settings_local_updated_at_v1`）、`settings_sections.dart`（4 组 section）、
  `settings_sync_service.dart`（拉/推/LWW/412/未知 v）、`settings_sync_coordinator.dart`
  （脏标记/去抖/单飞/状态）。
- 设置 controller 增加 `restoreFuture` / `applyRemote`；`main.dart` 的四个启动 override 不变。
- `ImmersivePageTracker` 挂在阅读页/播放页/设置页路由上；详情/搜索/缓存中心不挡。
- 同步记录新增 `scope`：`library` / `settings`，设置行用「设置」标记；设置无变化与
  deferred 不记录。
- 手动「立即同步」与保存配置并行跑书架 + 设置；设置页退出时 `SettingsSyncFlush` 补 flush。
- 测试：`test/settings_sync_test.dart`（推送/拉取/LWW/412/未知 v/沉浸页/脏值 clamp/coordinator）、
  `test/sync_log_test.dart` 与 `test/ui/sync_log_test.dart`（scope 往返与设置行）。

后续增补（2026-11-26）：新增 `mine` section（「我的」页模块顺序，存 name 数组，
脏值由 `mineSectionOrderFromNames()` 补齐成完整排列）。`SettingsSection` 变成 5 组，
coordinator 的监听来源与 `restoreFuture` 等待列表同步扩到 7 个；`settings.json` 结构不变，
仍是 `v: 1`（新增 section 只是多一个 key，老版本客户端推一次会丢这个 key，属已知退化）。
