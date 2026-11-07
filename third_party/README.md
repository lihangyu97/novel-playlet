# third_party

## video_player_avfoundation

- **来源**：pub.dev `video_player_avfoundation` **2.12.3**（[flutter/packages](https://github.com/flutter/packages)，BSD-3-Clause，LICENSE 随包保留）。
- **保留内容**：运行时需要的 `darwin/`、`lib/`，以及 `pubspec.yaml` / `LICENSE` / `README.md` / `CHANGELOG.md`；上游的 `example/`、`test/`、`pigeons/` 不拷入。
- **本地补丁**（`darwin/video_player_avfoundation/Sources/video_player_avfoundation/VideoPlayer.swift`）：
  `setPlaybackSpeed` / `updateRate` 同步 `AVPlayer.defaultRate`（iOS 16+ / macOS 13+）。
  AVPlayer 在起播、seek、缓冲恢复时会按 `defaultRate` 复位 `rate`；上游没有设置它，
  所以 `video_player` 报告 `playbackSpeed=2.0` 时实际会掉回 1.0x（UI 2x、实际 1x）。
  参考未合并的上游 PR：flutter/packages#8274。Dart 侧另有兜底（播放页在首帧/seek 后
  补设倍速，见 `docs/playback-quality-speed.md` §4.3）。
- **升级流程**：从新版 pub 包重新拷入上述目录 → 确认上游是否已修 `defaultRate` →
  未修则重放同一处补丁（两处 `applyDefaultRate` 调用 + 一个私有方法）→
  `flutter pub get && pod install` → 重跑 §7 真机倍速清单（尤其是 seek、切集、退出重进）。
- **约束**：不要在这个包里改其它逻辑；`video_player` 主包仍走 pub（版本 `^2.14.1`）。
