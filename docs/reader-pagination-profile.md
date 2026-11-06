# 阅读页分页耗时的真机 profile（P1-6 决策依据）

- 测量日期：2026-11-06
- 设备：iPhone 13（iPhone14,5，iOS 27.2 / Build 24B119）
- 构建：`flutter drive --profile`（profile 模式，USB 连接）
- 样本：合成正文，**150 段/章 × 12 章**，每段约 100 个汉字（长章；接近 `docs/architecture-review.md` 里"按 100 段估算"的上限场景）
- 采集：`SchedulerBinding.addTimingsCallback` 逐帧记录 `FrameTiming` 的 build/raster/span；判定预算 = 60Hz 的 16.7ms
- 用例：`integration_test/reader_pagination_perf_test.dart`（可复现，见文末命令）

## 结果

### 冷启动打开阅读页（目录 + 首章正文 → 整章分页）

| 指标 | 值 |
|---|---|
| 帧数 | 17（≈450ms，含首帧建树） |
| UI 线程 build | p50 0.11ms / p95 54.33ms / **max 61.72ms** |
| 超 16.7ms 的帧 | 2 帧（54.33ms、61.72ms） |
| raster max | 157.87ms（首帧，含着色器/首次光栅化，不全是分页） |

### 连续切 10 次章（每次都是新正文 → 整章重新分页）

| 指标 | 值 |
|---|---|
| 每次切章的帧数 | 14–22 帧（≈350ms，主要是 220ms 换章过渡动画） |
| UI 线程 build | p50 0.57ms / p95 1.13ms / **max 28.77ms** |
| 超 16.7ms 的帧 | **每次恰好 1 帧**（17.6–28.8ms，中位数约 19ms） |
| raster max | 2.21ms（切章时没有光栅压力） |

逐次 max：20.3 / 17.7 / 20.4 / 17.9 / 19.6 / 17.7 / 19.1 / 18.6 / 17.6 / **28.8** ms。

## 结论：P1-6 暂不实现（保持观察项）

1. **实测切章卡顿是 1 帧（≈18–29ms/150 段），不是文档静态推断的 20–50ms 持续卡顿**。
   按线性折算约 0.12–0.19ms/段：常见 60–80 段的章节约 8–15ms，基本在 16.7ms 预算内；
   只有 150 段以上的超长章才会稳定掉 1 帧。
2. 阅读页在切章时是"保留上一章正文 + 顶部加载 pill"，用户看到的不是白屏；掉 1 帧的观感代价很小。
3. 文档建议的「只量首屏 + 2 页，剩余分帧补」会让**页数从"部分"变成"最终"**（页码条跳变、
   章末判断延后），这个观感代价与"每次切章少掉 1 帧"相比不划算。
4. 冷启动首开阅读页确实有 2 帧 54–62ms 的 build（分页 + 首帧），但其中包含首次建树/光栅化；
   如果以后要优化首开手感，更值得做的是**在空闲帧预分页下一章**（`scheduleIdleCallback`，
   命中后切章直接复用缓存、页数稳定），而不是分帧补页。这个方案复杂度不低，等真机实际
   感到卡顿再说。

> 备注：本次只测了合成长章。若以后要在真实书目的超长章节上复核，重跑下面命令即可；
> 想换段落数，把 `--dart-define=PERF_PARAGRAPHS=<n>` 传进去（默认 150）。

## 复现

```bash
# 需要 iPhone 用 USB 连接（无线调试下 flutter drive 经常找不到 Dart VM Service）
flutter drive --profile -d <iPhone UDID> \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/reader_pagination_perf_test.dart

# 结果落在 build/reader_pagination_perf.json（逐帧原始数据也在里面）
```

注意：跑完手机上的 App 会被测试 runner 覆盖（同 bundle id），需要重新安装正常构建：

```bash
cd ~/workspace/ios-sideload
DEVICE=<iPhone UDID> ./install.sh -f build/novel_playlet_unsigned-signed.ipa
```
