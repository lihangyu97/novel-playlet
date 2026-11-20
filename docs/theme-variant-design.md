# 主题「配色算法」可选档位

**相关**：[implementation.md](implementation.md) §设置、[settings-sync-design.md](settings-sync-design.md)

## 1. 背景

主题色原来是「一个种子色 + 一个固定算法」：`ColorScheme.fromSeed` 走 M3 默认的
`tonalSpot`，近中性色（白/灰/黑）例外走 `monochrome`。这带来一个用户能直接感知
的落差——**挑了很艳的颜色，主色出来却是柔和款**：`tonalSpot` 会丢掉种子自己的
彩度（primary chroma 固定 36），只保留色相。

M3 的 `DynamicSchemeVariant` 本来就是「同一套生成流水线 + 不同参数」：种子 →
HCT → 5 条 tonal palette（primary / secondary / tertiary / neutral /
neutral-variant）→ tone 映射表。变体只改前两步里的 **hue 与 chroma**，tone 映射
表完全一致，所以**换算法不会破坏对比度**。

## 2. 方案：只放开 4 档

| 档位 | `DynamicSchemeVariant` | 对种子的处理 | 一句话 |
|---|---|---|---|
| 标准（默认） | `tonalSpot` | 只取 hue，彩度固定 36/16/24 | 最「M3 官方」，柔和统一 |
| 忠实 | `fidelity` | 彩度改用种子自己的 | 主色接近你挑的颜色本身 |
| 鲜艳 | `vibrant` | 彩度顶到该色相上限（常见 200） | 能多艳就多艳 |
| 活泼 | `expressive` | 彩度略高 + 二/三键色色相错开 | 三键色互相拉开，更跳 |

`rainbow` / `fruitSalad` 没有放出：它们是 `material_color_utilities` 的实验变体，
色相漂移幅度大，做成选项只会让配色看着失控。`neutral` / `monochrome` 也没放：
它们是「去掉颜色」的档位，与「用主题色表达品牌」相反，且近中性种子已经自动走
`monochrome`。

**默认值仍是 `standard`**，老用户升级后观感不变；`AppAccent` 里的 `variant`
字段默认 `standard`，`AppTheme.light/dark/themed` 的第三个位置参数可选，所以
`test/goldens` 里那些不传算法的用例派生结果与升级前完全一致。

## 3. 实现落点

| 位置 | 改动 |
|---|---|
| `app_theme.dart` | `enum AppThemeVariant`（label / scheme / description）+ `appThemeVariantFromName`；`schemeFor` / `light` / `dark` / `themed` / `_build` 增加可选 `variant`；`AppAccent` 增加 `variant` 字段；新增 `AppTheme.variantOf(context)` |
| `theme_settings.dart` | `themeVariantProvider` + `ThemeVariantController`（prefs key `app_theme_variant_v1`，存枚举 **name**，与 `ThemeModeController` 同一套 `restoreFuture` / `applyRemote` 模式） |
| `main.dart` | 启动预读并入同一次读盘，避免首帧先按「标准」渲染再跳档 |
| `app.dart` | `watch(themeVariantProvider)`，传给 `AppTheme.light/dark` |
| `settings_page.dart` | 主题卡新增「配色算法」行（`SegmentedButton`，四档），位置紧跟「主题色」 |
| `theme_color_picker.dart` | 预览带上当前档位（memo 维度从 seed×brightness 变成 seed×brightness×variant） |
| `reader_page.dart` / `reader_comments_sheet.dart` | 局部重建 scheme 时传 `AppTheme.variantOf(context)`，保证阅读页工具栏/弹层与全局一致 |
| `settings_sections.dart` | 同步快照 `theme.variant`（name 字符串），缺失/不认识回落 `standard` |

### 为什么 variant 放进 `AppAccent`

阅读页与评论弹层挂在不同 Navigator 上，靠 `context` 反查不到设置页的 provider
（`reader_comments_sheet` 是纯 `StatelessWidget`，没有 `ref`）。`AppAccent` 本来
就是「原始 seed 的搬运工」，把 `variant` 一起带上，两处只需
`AppTheme.variantOf(context)`，不用改组件类型。

`AppAccent.lerp` 对 variant 用 `t < 0.5 ? this : other` 硬切：算法是离散档位，
没有中间态，否则主题动画期间会派生出「60% 的种子 + 40% 的算法」这种假值。

## 4. 已知边界

1. **近中性种子永远走灰阶**（HSV 饱和度 < 0.08）。选了「鲜艳」再挑白/灰主题色，
   结果仍是灰阶——这是刻意的：其余变体都会固定或抬高彩度、只取 hue，而灰阶的
   hue 数值不稳定，纯白会变青、纯黑会变粉。UI 副标题里写明了「近灰主题色始终
   用灰阶」，避免被当成 bug。
2. **可见变化面有限**。`lib` 里仍有约 133 处硬编码颜色，其中 `video_player_page.dart`
   （37）、`comment_image_viewer.dart`（10）、`theme_color_picker.dart`（8）属于
   媒体黑底/取色器色块，本来就该钉死。换算法真正会动的是 `FilledButton`、导航
   指示器、`SegmentedButton`、`divider`、卡片底色这几个 role；白卡、画布
   `#F7F7F8`、正文 `#1B1B1B` 是常量，不跟算法走。
3. **同步双向兼容**：旧快照没有 `variant` 字段 → 新客户端按 `standard` 处理；
   新快照多出 `variant` → 旧客户端只读它认识的 key，不会炸。

## 5. 后续可做（未包含在本分支）

- 颜色 token 收口：把 `AppTheme.ink / subtleInk / surface / canvas` 换成
  `colorScheme` 的语义角色，让「跟随算法」的面变大；这是数据库/视觉回归级的活，
  建议单独排期，先做 alias 零视觉变更，再逐模块替换。
- 若要让主色更贴近用户所选，可考虑把默认档从 `standard` 换成 `fidelity` 做 A/B。

## 6. 验证清单

本分支在**无 Flutter SDK、无网络**的环境下完成，代码未在本机跑过测试，合并前需在
有 SDK 的机器上补跑：

```bash
flutter pub get
flutter analyze
flutter test test/settings_test.dart test/settings_sync_test.dart
# 设置页新增了一行「配色算法」，设置页 golden 必然变化，需重生成：
flutter test --update-goldens test/ui/settings_page_test.dart
```

重点回归：

1. 设置页切换四档 → 按钮/导航指示器/按钮组选中色立即变，白卡与正文不变；
2. 切到「鲜艳」再挑白色主题色 → 仍是灰阶（副标题已说明）；
3. 阅读页（尤其夜间纸色）工具栏高亮与全站一致；
4. 取色弹层里的预览与确定后的观感一致（含「鲜艳」档）；
5. 云同步：A 机切「活泼」→ 上传 → B 机拉取后档位与配色一致；
6. 重启 App 首帧就是上次选的档位（无跳档闪烁）。
