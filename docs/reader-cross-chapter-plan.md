# 阅读器跨章流畅度：现状核实、问题记录与方案评估

> 记录日期：2026-11-16
> 状态：**未动代码**，本文只是调研结论 + 待做清单。
> 关联分支：`feat/lhy/reader-cross-chapter-window`

## 1. 目标

1. 搞清楚现在的切章观感为什么"回上一章像闪回第一页再跳到最后一页"；
2. 决定渲染窗口要不要从「当前章 + 前后各 1 页 sentinel」扩成「当前章 + 前后章」；
3. 把三个容易反复确认的现状事实（防抖、渲染范围、回章落点）固定下来，后续不再重复排查。

## 2. 现状事实（已逐条核对代码）

### 2.1 进度落盘：400ms 防抖 + 三处立即 flush

- 防抖：`_progressDebounce = 400ms`，`noteReadingBlock()` 重开计时器，到点 `_flushPendingProgress()`
  → `ReadingStore.saveProgress(blockIndex)`（`lib/features/reader/reader_controller.dart:131-134, 712-741`）。
- 落盘内容是**当前页首段下标** `blockIndex`，不是页码，改字号重排后仍可定位。
- 立即 flush 的三处：切章前（`reader_controller.dart:383-384`）、页面 dispose
  （`lib/features/reader/reader_page.dart:191-214`，先 `cancelProgressTimer()` 再直接写）、
  切章瞬间写目标章 `block 0`（`reader_controller.dart:399-402`）。

### 2.2 渲染范围：一章 + 左右各一页 sentinel

- `PageView.builder`，`itemCount = displayOffset + 当前章页数 + (有下一章 sentinel ? 1 : 0)`
  （`reader_page.dart:511-513`）。
- 前面最多 1 页 = 上一章**最后一页**；后面最多 1 页 = 下一章**第一页**（`:545-580`）。
- 邻章确实都"准备"了，但只准备数据、不进渲染树：`_schedulePreparation` 对 `contentIndex ± 1`
  拉正文（`prepareChapterContent`）→ 拉章评 → 整章分页，存进 `_prepared`，窗口只留三章，
  `_prunePrepared` 淘汰（`:1009-1127`）。
- 稳态下 `PageView` 只有可见页在树上（Flutter 把 `cacheExtent` 写死成
  `allowImplicitScrolling ? 1.0 : 0.0`），每页一个 `RepaintBoundary`。

### 2.3 回上一章：落最后一页

- 落点枚举 `_ChapterEntry.lastPage`（`reader_page.dart:54-56`），点击左分区 / 章边界滑动 /
  `_turnPage` 负方向都设它（`:893-895`、`:1282`）。
- 上一章已预排版（常态）：PageView 第 0 页就是上一章最后一页，`animateToPage(0)` 滑过去，
  落定后 `_commitSentinel(-1)` 原子切章（`:829-880`）。
- 上一章未预排版：`_pendingEntry = lastPage` → 切章 → 分页算完后取
  `pages.length - 1` 作为新 `PageController` 的 `initialPage`（`:969-977`）。

### 2.4 疑似闪帧点（要先验证，再谈重构）

- `_settlePage` 覆盖层**只在 sentinel 路径**设置（`reader_page.dart:852`）；`_turnPage`
  的 fallback 分支（`:1280-1285`）没有覆盖层，只有 `_stabilizeController` 事后校正 3 帧
  （`:1188-1212`）。"回到第一页再回来"很可能就是这条路径的 clamp 闪帧。
- 空章兜底的「上一章」按钮直接 `controller.previousChapter()`，没设 `_pendingEntry`
  （`:400-405`）→ 走默认 `firstPage`，会落第一页。

### 2.5 测试缺口

- 没有"回上一章落最后一页"的 widget 测试（`test/ui/reader_test.dart` 里只有
  `childCount = 当前页数 + 1`、`controller.page == 1` 这类 sentinel 断言，`:198-290`）。
  → 重构前后都需要补这条断言，否则回归无感。

### 2.6 离线正文格式

- `offline/novel/<bookId>/book.json`（目录 manifest）+ 每章 `<chapterKey>.json`
  （`paragraphs: List<String>` + 可选 `paraIndices` + `v` schema 版本）
  → `lib/core/storage/offline/offline_book_store.dart:52-113`。

## 3. 主流做法（2026-11 调研）

| 项目 | 分页单位 | 跨章处理 | 关键参数 |
|---|---|---|---|
| Readium（iOS/Android/Web/Flutter） | 每个 spine item（≈一章）一个资源视图 + CSS 多栏 | 换到相邻 spread 视图，`PaginationView` 保留已加载邻页视图 | `preloadPreviousPositionCount = 2`、`preloadNextPositionCount = 6`；`loading/jumping/moving` 期间禁用交互 |
| foliate-js | 每章一个 iframe + CSS 列 | 到边界 `#goTo` 相邻 section，**prev 显式 `anchor: () => 1`（= 最后一页）** | 切章期间 `#locked` 锁输入 + `wait(100)`；只有 `flow="scrolled"` 才连续 |
| Legado 系 | 按章分页 | 章边界换页 + 相邻章预热 | 预热 4 章（流畅）/ 6 章（极致）；复用已排版 WebView；手指按下暂停后台排版；预取串行 + Promise 复用 + generation 失效 |
| Flutter 生态 | 整章 `TextPainter` 分页 | PageView / 有人直接换 ListView（扁平页） | `PageView` 默认不预建邻页（`cacheExtent` 写死） |

结论：主流在「左右翻页」模式下**不会整章预渲染**，做的是「邻章视图预先加载 + 切章复用」；
真正"无章边界"的体验来自滚动/扁平页列表模式。

## 4. 方案评估

### V1b：上一章全部页 + 下一章首页（你提出的版本）

- 改动集中在 `displayOffset` 与 itemBuilder 的映射；回退连续，前进仍需换章。
- 问题：只要"当前章"变了就要重排 offset，仍然要换 `PageController`，sentinel/覆盖层/校正
  三件套继续留着，只是把重建点从第 1 页挪到了最后一页。

### V2：单 PageView 扁平页列表（推荐）

- 数据层已经具备（`_prepared` 里有 ±1 章的完整分页），只缺"页列表拼接 + 绝对页原点"索引层。
- 跨章 = 普通翻页，不再换 controller；`_commitSentinel` / `_crossChapter` / `_settlePage` /
  `_stabilizeController` / `_displayOffset` / `_pendingEntry` 可以整批删掉。
- 窗口管理规则：**尾部 append（安全）**；头部裁剪必须同帧补偿索引（`jumpToPage(visible + P)`），
  或留 2 章冗余让裁剪很少发生。
- 风险清单：头部插入索引漂移、进度/页码/章名改按"可见页所属章"、失败态空洞、空章 0 页、
  目录跳章整窗重建、改字号三章重排、章评请求数、测试重写（详见下方"待做"）。

### V3：3 章拼成一个字符串 + 按字符切片只渲染 3 页

**不推荐**，理由是渲染保真度会从"契约"退化成"碰运气"：

1. `TextAlign.justify` 会把**段落最后一行**排除在两端对齐外；按页切片后，每页最后一行都变成
   "最后一行"，页尾会从两端对齐退化成左对齐。
2. 首行缩进是 `WidgetSpan` 占位；跨页续排的页首必须不带缩进，段首页必须带——切片侧要单独判断。
3. 段评气泡也在最后一行占位；切片必须只在"包含段落结尾的那一页"带上同样尺寸的占位。
4. 对话高亮矩形是**段内坐标**（`getBoxesForSelection` 的结果），切片后要重算或重定位。
5. 需要新增"字符 ↔ 行"映射（现在 `ReaderBlock` 只有 `lineTops/lineHeights`，没有每行字符范围）。
6. 选区跨页、语义树、段评 `paraIndices` 锚点在切片模型下都会断。
7. 现有实现刻意让"测量"和"渲染"共用同一份宽/样式/`TextScaler`/`TextHeightBehavior` 与整段
   span（`reader_pagination.dart:10-17`、`reader_widgets.dart:13-17`）；切片等于主动放弃这条契约。

另外两点：

- "只渲染 3 页"现在已经是 PageView 的行为（`cacheExtent = 0`），再加也只会多占内存；
  若要确定性预建 1 页，用 `allowImplicitScrolling: true` 即可。
- 拼字符串在**上下滚动模式**下才是对的（那里本来就需要连续文本流）。如果以后做滚动模式，
  这个思路可以直接拿来用。

## 5. 推荐实施顺序

1. **先定位根因（半天）**：回上一章时打点确认走的是 sentinel 还是 fallback；给 fallback 分支
   也加 `_settlePage` 覆盖，验证"闪回第一页"是否消失。
2. **低成本优化（1 天）**：邻章预排挪到 `SchedulerBinding.scheduleIdleCallback`；手指按下时
   暂停后台排版；空章按钮补 `_pendingEntry`；补"回上一章落最后一页"的 widget 测试。
3. **再决定 V2 是否做**：若第 1 步就解决观感，V2 按"架构健康度"排期；真要做，按
   「单 PageView + 窗口页列表 + 只 append 尾部 + 头裁剪同帧补偿」的形态做，
   完成后跑 `integration_test/reader_pagination_perf_test.dart` 对比切章帧耗时。

## 6. 待确认

- 渲染窗口取 ±1（3 章）还是 ±2（5 章）？后者分页与章评请求都会上升。
- 回上一章：落最后一页（现语义，与 Readium/foliate 一致）还是恢复上次离开该章的位置？
- 跨章是否需要在章首加一个标题页/过渡，避免"滑过去不知道换章了"？

## 参考

- Readium Swift `EPUBNavigatorViewController`（`preloadPreviousPositionCount = 2` / `preloadNextPositionCount = 6`、导航状态机）
- Readium CSS 分页模型：<https://readium.org/css/docs/CSS03-injection_and_pagination.html>
- foliate-js `paginator.js`（`#turnPage` / `#goTo` / `anchor: prev ? () => 1 : () => 0` / `#locked`）
- Legado 功能说明（预热 4–6 章、复用已排版 WebView、手指按下暂停后台排版）
- Legado 踩坑记录（相邻章预取串行 + Promise 复用、进度 5s latest-wins + 60s 上传 + 切章 flush）
- Flutter `PageView` 的 `cacheExtent: allowImplicitScrolling ? 1.0 : 0.0`
