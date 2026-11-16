# TODO

## Android 全局字重（已完成 2026-11-15）

- 设置页新增「全局字重」滑块，仅 Android 显示/生效，默认 400，范围 300–700，持久化 key `app_font_weight_v1`。
- `AppTheme` 会把完整 `textTheme`、组件主题和页面里写死的强调字重一起平移；iOS 的 effective 值恒为 400，保持原样。
- 阅读器正文默认跟随全局字重；阅读器设置里新增「跟随全局字重」开关，关闭后可单独调 300–800 并覆盖全局。老版本已存过阅读器字重（`reader_font_weight_v1`）的用户迁移为不跟随，避免升级后设置丢失。
- 系统栏、图标、图片内文字按约定不处理。

### 后续可选

- Android 系统字体对中间字重可能做合成，滑杆档位观感不一定完全线性；若要更稳定，可评估打包带完整字重的字体（注意授权和包体）。
- iOS 若要换成统一的跨平台字体，需要另行处理字体文件与授权，不在本次范围内。

## 短剧在线取流停摆（2026-11-16，待决）

- 上游把匿名「播放地址」接口关了：`video_model/v1`、`multi_video_model/v1`、
  `multi_video_model/player/v1` 对所有剧集/全部镜像一律 `HTTP 200 + 0 字节`；同一设备下
  搜索/评论/详情正常，小说不受影响，已缓存/离线集可播。
- 已落地：内核把空/截断响应当瞬时失败重试 1 次，仍失败归 `upstream_5xx` + 人话，
  非 JSON 不重试，`rust.log` 记录剧集 id/接口/字节数；测试
  `rust/tests/video_model_empty_body.rs`。**不恢复播放**。
- 待决：A 登录态（唯一已知可恢复，需评估账号风控/协议/法律风险，建议 feature flag 默认关、
  只存 token、仅自用）；B 等匿名恢复；C 换源（网页仅前 3 集）。
- 详见 [docs/playlet-playback-outage-2026-11.md](docs/playlet-playback-outage-2026-11.md)。
