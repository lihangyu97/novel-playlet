# TODO

## Android 全局字重设置（仅 Android，iOS 写死）

状态：待做（计划 2026-11-16）

### 目标

- 设置页新增「全局字重」选项，**仅 Android 显示并生效**。
- iOS 不显示该选项，字体粗细继续使用当前写死的值，不做任何变化。
- Android 默认档位必须与当前观感一致；调节后整个 App 的正文、标题、按钮、导航等一起变化并持久化。
- 阅读器已有独立字重设置，需要先明确策略：建议全局设置只作用于 UI，阅读器保持自己的设置；若要让 Android 阅读器跟随全局，需要额外处理分页缓存。

### 现状与难点

- `lib/app/theme/app_theme.dart` 没有集中维护 `textTheme`，大量组件主题（AppBar、NavigationBar、FilledButton、OutlinedButton 等）各自写权重。
- 全仓约 90+ 处 `fontWeight: FontWeight.w600/w700`，分布在 20 多个文件；只改 `ThemeData.textTheme` 会出现“正文变细、标题/按钮仍很粗”的半套效果。
- `TextTheme.apply` 没有 `fontWeightDelta` 参数，需要逐个 style `.apply(fontWeightDelta: ...)` 或封装 helper。
- 设置页测试默认运行在 macOS，平台判断建议用 `Theme.of(context).platform` / `defaultTargetPlatform`，Android 用例需要临时覆盖 `debugDefaultTargetPlatformOverride`。
- Android 系统字体对中间字重可能做合成，滑杆档位观感不一定线性；如果要真正稳定，后续可考虑打包带完整字重的字体（另行评估授权和包体）。

### 实现建议

1. 新增 `AppFontWeight` / `appFontWeightProvider`，仿照 `themeSeedProvider`、`recommendLayoutProvider`：
   - 默认档 = 当前值；
   - `main.dart` 启动预读，避免首帧跳变；
   - 持久化 key，例如 `app_font_weight_v1`。
2. 扩展 `AppTheme.light/dark`（及 `themed`）接收字重参数：
   - iOS 传 `null`，主题保持现有值；
   - Android 传用户档位，统一平移 `textTheme` 与组件主题。
3. 把散落的 `FontWeight` 收成语义 token（正文 / 次要 / 强调 / 标题），或提供 `context.appWeight(...)` helper；至少覆盖：
   - `app_theme.dart` 的组件主题；
   - 设置页、详情页、推荐流、播放页、弹层等主要页面；
   - 底栏/导航的选中与非选中态。
4. 设置页增加仅 Android 可见的卡片：
   - 用平台判断控制渲染；
   - 滑杆或分段档位（建议 300–700，默认 400）；
   - 变更后立即 `MaterialApp` 重建生效。
5. 阅读器策略二选一：
   - 推荐：全局只作用于 UI，阅读器保留现有 `reader_font_weight_v1`；
   - 或全局作为阅读器默认值，阅读器内可覆盖；变更时需重新分页（`ReaderPagination` 的 key 已含 `fontWeight`）。
6. 测试与 golden：
   - Android 平台覆盖下设置页出现卡片、滑动后主题权重变化；
   - iOS/macOS 平台下不出现卡片、主题权重不变；
   - 更新受影响的 golden。

### 验收

- Android：设置页可见「全局字重」，调整后所有主要界面同步变粗/变细，重启后保持。
- iOS：设置页没有该入口，字体权重与当前版本完全一致。
- 默认档位下 Android 观感与改动前一致。
- `flutter analyze --fatal-infos` 干净，相关测试通过。

### 相关文件

- `lib/app/theme/app_theme.dart`
- `lib/app/app.dart`
- `lib/main.dart`
- `lib/features/settings/settings_page.dart`
- `lib/features/reader/reader_settings.dart`
- `lib/features/reader/reader_pagination.dart`
- `test/ui/settings_page_test.dart`
- `test/ui/preview_harness.dart`
