# 书城首页流：tab_type 分类对照

> 状态：实测 + 与 fqapp（同仓库族，Android/Windows，已跑通全部书城分类）对齐。
> 用途：以后加「漫剧 / 漫画 / 听书」tab、或者排查「某个 tab 出来的卡片类型不对」时先看这里。

## 1. 结论

小说、短剧、漫剧、漫画、听书这些分类**不是不同的接口**，而是**同一个书城首页接口**，靠 `tab_type` 区分：

```
GET /api/v1/recommend/homepage
  ?tab_type=<分类>
  &offset=<页码游标>
  &tab_index=<请求哪个顶栏项，一般 0>
  &session_id=<翻页必须回传>
```

内核对应实现：`rust/src/endpoints/recommend.rs`（`/api/v1/recommend/homepage`），Dart 侧入口：`lib/data/api/api_client.dart` 的 `recommend()`（小说）与 `videoFeed(tabType:)`（短剧 8 / 漫剧 24）。合并后的推荐页按搜索框下方的分类 tabs 调用：`lib/features/recommend/recommend_category.dart` 里的 `tabType` 就是这张表的取值。

短剧搜索是另一条接口：`GET /api/v1/search?tab_type=11`（见 §4）。

## 2. tab_type 对照表

官方枚举是 `BookstoreTabType`（`com.bytedance.kmp.reading.model.BookstoreTabType`）。fqapp 抄录在 `fqapp/lib/models/channel_tab.dart`，并整理成 `fqapp/lib/pages/home_provider.dart` 的 `_kindByTabType`：

| tab_type | 官方枚举 | 内容 | 实测行为（2026-11-04） |
|---|---|---|---|
| 2 | recommend | 小说推荐（书城首页默认） | 22 张卡/页左右，可翻页，`session_id` 稳定 |
| 3 | new_book | 新书 | 未见下发 |
| 5 | audio | 听书 | 首页流有；卡片是 audio 模板 |
| 8 | video_episode | **短剧（看剧）** | **6 张/页，`next_offset` 逐页 +1，可翻页**；响应 `tab_type=8`、title「看剧」 |
| 9 | comic | 漫画 | 首页流有；fqapp 走搜索兜底 |
| 11 | classic | 经典（书） | 首页流有 |
| 12 | knowledge2 | 知识（书） | 首页流有 |
| 15 | ecom_book | 商城 | 首页流有 |
| 16 | video_feed | 视频 feed（短剧视频流） | ❌ 只回 **2 张卡**、`has_more=false`、无游标（别用） |
| 18 | recent | 最近（本地历史，不请求） | — |
| 24 | dynamic_comic | 漫剧 | 12 张卡，但 offset>0 返回空（无游标，只能首页） |
| 25 | novel | 小说 | 首页流有 |
| 30 | follow | 收藏（本地，不请求） | — |
| 31 | latest_published_book | 新书 | 首页流有 |
| 103 | ugc_story | 短篇（UGC） | 首页流有 |

fqapp 的 7 个 tab 与取值（`home_provider.dart` 的 `tabTypes`）：

```dart
static const tabTypes = {'小说': 2, '短剧': 8, '漫剧': 24, '听书': 5, '视频': 16};
// 「全部」在内部也是用 tab_type=2 去拉，再和搜索兜底合并
// 漫画（9）没有进这个表：fqapp 只用搜索流
```

## 3. 必须遵守的两条规则

### 3.1 响应要按 `tab_type` 认领，否则会串台

上游的 `data.tab_item` 是**整条顶栏**：只有被回答的那一项带 `cell_data`，其余项只有标题；`data.tab_index` 指向被回答项的位置。客户端必须读 `tab_item[tab_index].tab_type`，**等于自己请求的值才能用这份数据**，否则就是别的分类的流。

fqapp 的做法：`HomeNotifier._answersTab()` / `homePageAffinity()`，不匹配整页拒绝。本项目：
- `recommend()`（小说）：目前取 `data.tab_index` 指向的 tab 读游标（上游一直回 `tab_type=2`，未加硬校验）。
- `videoFeed(tabType:)`（短剧 8 / 漫剧 24）：**已加校验**——被回答 tab 的 `tab_type` 与请求值不一致直接抛 `ApiException('推荐数据异常，下拉刷新试试')`。

串台的典型症状（fqapp 踩过）：在「听书」tab 里画出推荐榜/猜你喜欢的小说卡片，因为页面把别的分类的 `cell_data` 当成了自己那份。

### 3.2 翻页只认游标前进

`has_more` 不可信（小说流实测 `has_more=false` 时继续 `offset+1` 仍有新书）。统一规则：`next_offset > 当前 offset` 才算有下一页，否则当到底。短剧流（8）实测 0→1→2 每页都有新剧。

## 4. 搜索接口的 tab_type

`GET /api/v1/search?query=<kw>&tab_type=<n>&offset=&count=`：

| tab_type | 内容 |
|---|---|
| 1 | 综合 |
| 2 | 听书 |
| 3 | 书籍/小说 |
| 8 | 漫画 |
| 11 | **短剧** |

本项目：`search()` 用 3（小说），`searchVideos(tabType:)` 短剧用 11、漫剧暂用 8（漫画，上游没有「漫剧」搜索 tab）。

## 5. 翻页与兜底（fqapp 的做法，本项目可选补）

- 推荐流游标耗尽后，fqapp 回退到**同分类搜索流**继续翻页（`_searchByType`），避免「只有首页那几屏」。短剧这类推荐池小的分类尤其明显。
- 漫剧（24）没有游标：fqapp 首页用推荐流，后续页全用搜索兜底。
- 本项目现状：短剧游标翻完显示「没有更多了」，漫剧只展示首页一屏；三个分类都尚未接搜索兜底（`docs/video-playback.md` 4.1-5 有记录）。

## 6. 怎么复核

```bash
# 用内核 + 真实上游直接看某一类的原始响应（示例：短剧=8）
LIVE_PROBE=1 flutter test test/live_probe_test.dart   # 现有探针：小说链路
```
临时探针写法见 `test/live_probe_test.dart` 顶部注释：`RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/debug/libfqapi_core.dylib'))`
→ `transport.send('GET', '/api/v1/recommend/homepage', query: 'tab_type=8&offset=0&tab_index=0')`
→ 打印 `data.tab_index` 指向项的 `tab_type/title/next_offset/session_id`，用 `parseVideoSeries` / `parseNovelItems` 数卡片。

## 7. 参考

- `fqapp/lib/models/channel_tab.dart`：官方 `BookstoreTabType` 常量与「服务端下发的频道表」解析
- `fqapp/lib/pages/home_provider.dart`：`tabTypes` / `_kindByTabType` / `_answersTab` / 搜索兜底翻页
- `fqapp/lib/models/media_item.dart`：各分类卡片的字段兼容（短剧 `series_id_str`、漫剧标记等）
- `docs/video-playback.md` 4.1-5：短剧流从 16 换成 8 的实测记录
