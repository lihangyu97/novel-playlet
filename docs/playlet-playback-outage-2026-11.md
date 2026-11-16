# 短剧在线取流停摆排查记录（2026-11-16）

## 现象

iPhone release 包播放《强悍亲娘带飞全家第五季》第 36 集（`id=7702288607674895384`）
失败，错误页原文：

```
parse upstream json: EOF while parsing a value at line 1 column 0
错误类型: ApiException
堆栈: ApiClient._getJson (api_client.dart:575) / ApiClient.videoSource (api_client.dart:234)
```

用户多次点重试、换蜂窝网络均无效。当天上午还能播（同一个 release 包没变）。

## 结论（一句话）

**不是本地的解析/缓存/解码问题**：内核向上游请求「这一集的播放地址」时，上游回的是
`HTTP 200` + **0 字节** body，serde 解析空串就报 `EOF ... column 0`，再被原样透成
`kind=unknown` 的 `ApiException`。

更重要的结论：**短剧在线取流是整体停摆**，而且上游本周把「匿名读播放地址」这条口子关了，
目前已知还能取址的路径是**登录态**（账号 `X-TT-Token` + cookies）。

## 影响面

| 能力 | 状态 |
|---|---|
| 在线短剧起播 / 整集取流 / 清晰度面板 | ❌ 全部失败（所有剧、所有集） |
| 已缓存集（`mode=cached`）、离线下载好的集 | ✅ 不受影响（不打上游取流） |
| 小说阅读 / 搜索 / 详情 / 目录 / 评论 | ✅ 正常 |
| 短剧详情、选集、剧评 | ✅ 正常（走 `video_detail` / `comment` 等读接口） |

## 复现与证据（2026-11-16 实机 + 本机）

用本机真实注册设备（`device_register` 成功，同一套 Argus/Ladon/Khronos/Stub 签名）实测：

| 请求 | 结果 |
|---|---|
| 搜索 / 推荐 / 剧评（POST） / `video_detail`（POST） / `/reading/media/video/info/` | 正常 JSON |
| `POST /novel/player/video_model/v1/`（番茄单集取流，aid=1967） | `200`，`content-length: 0` |
| `POST /novel/player/multi_video_model/v1/`（红果 phoenix 取流，aid=8662） | `200`，`content-length: 0` |
| `POST /novel/player/multi_video_model/player/v1`（hongguo 用的新路由） | `200`，0 字节 |
| 任意未知路径 `/novel/player/definitely_not_a_route/v1/` | `404 text/plain`（说明上面几条路由存在，是网关静默拒绝） |

- 范围：搜索结果里 6 部短剧、每部多集、**7 个镜像**（`api5-normal-sinfonlinea/b/c`、
  `lf`、`lq`、`hl`、`api5-normal`）全部 0 字节。
- 响应头带 `x-dsa-origin-status: 200`（源站自己回的 200）和 `x-tt-trace-tag: id=5`，
  是典型的「网关静默拒绝」而不是错误封套。
- 换蜂窝网络同样失败 → 排除单 IP 风控；真实注册设备 + 其它接口正常 → 排除设备/签名整体失效。

## 已排除的假设

1. **单集数据问题**：否。同剧相邻集、其它剧的所有集一致失败。
2. **设备/注册问题**：否。同设备 search/comments/video_detail 全正常。
3. **IP 级风控**：否。蜂窝网络（不同出口）仍失败。
4. **版本门槛**：否。`version_code` 72132 / 73532 / 73932 均 0 字节。
5. **缺 `X-Gorgon`**：否。开启 gorgon（旧 8404 变体）仍 0 字节。
6. **请求形态**：gzip body + `Content-Encoding: gzip`、大写 `x-ss-stub`、`preload` 端点
   （含文档里的 `klink_egdi` + `Referer`）、`aid` 8662/1967 两种身份 → 全部仍 0 字节。
7. **「六签名」（Helios/Medusa）**：不是充分条件。见下一节实测。

## 参考 hongguo 桌面版 1.0.29 源码的发现

源码包（GitHub Release 的 `hongguo-1.0.29-third-party-sources.zip`）里有完整 Python 后端，
逐层跑通后的结论：

- 新路由是 `POST /novel/player/multi_video_model/player/v1`（不是 `v1/`，也不是 `preload/v1`），
  body 为 `{"dr_scene":"player","mixed_video_id_map":{"1004":[vid]},"biz_param":{…device_level:4…}}`。
- 匿名链路（`desktop_public_player.py` / `desktop_fresh_playback.py`）需要：
  `device_register` 拿 `device_id/iid/device_token` + cookies → query 里加 `_rticket`/`ts`，
  用一个 **SM3 selector 循环**挑 `_rticket` → 带 `X-Medusa`（他们唯一的真实实现）等头。
- 我按它原样在本机跑了完整匿名链路（含真实注册、SM3、Medusa）：**仍然 `200 / 0 字节`**；
  再把**我们内核里真实的 Argus/Ladon** 叠上去重发：**仍然 0 字节**。
- 他们源码里的另外几个签名是**占位**：`X-Argus`/`X-Ladon` = `base64(4 字节时间戳)`，
  `X-Helios` 直接拿 `ladon_encrypt` 顶替；所以「六签名」既不是他们匿名可用的原因，
  也不是我们这边的瓶颈。
- 真正让 hongguo 能播的是**登录态**：`phone_account_media.read_media()` 开头即要求
  `flow.uid` + `authenticated_cookies()`，用**同一条路由、同一个 body**，只多
  `X-TT-Token`、`X-TT-Passport-Csrf-Token` 和账号 cookies；`desktop_account_player.py`
  的注释写得更直白：「Recover an empty public media response using this user's saved account」。

即：**上游把播放地址接口从「游客可读」切成了「要登录态」**，时间点与「昨天还能播、今天挂」
吻合（我们的 stream 主通道 shortplay 先挂，phoenix 早就空，于是兜底也失败）。

## 已落地的改动（本分支）

- `rust/src/endpoints/video.rs`：空/截断响应按瞬时失败重试 1 次（250ms）；仍为空返回
  `kind=upstream_5xx` + 「上游没有返回取流数据（空响应），请稍后重试」；非空非 JSON 保持
  `Internal` 且不重试；每次失败 `log::warn` 记录剧集 id / 接口 / 尝试次数 / 字节数。
- `rust/tests/video_model_empty_body.rs`：3 个契约测试（空→重试成功；持续空→500+`upstream_5xx`
  +人话且只打 2 次；非 JSON 不重试）。
- `PATCHES.md` §3.8、`docs/implementation.md` §5.3：记录现象与结论。

注意：这个补丁只改善**可读性与自愈**，**不能恢复播放**（上游拒绝是确定性的）。

## 待决方案（过两天再看）

| 方案 | 说明 | 成本/风险 |
|---|---|---|
| A. 登录态 | 手机号验证码/扫码拿 Passport session（只存 token），取流时带 `X-TT-Token` + cookies，用 hongguo 的 `phone_account_*` 作参考 | 唯一已知可恢复的路；成本按天算（Passport 移植 + 登录 UI + Keychain + 失效重登）；账号有风控/封号风险，法律上个人自用低、**分发会显著放大** |
| B. 等匿名恢复 | 上游可能灰度回滚，也可能永久关 | 零成本，不确定 |
| C. 换源 | 网页版每剧只公开前 3 集；第三方聚合接口需评估稳定性/合规 | 只能降级 |

风险排序（若做 A）：**账号风控 > 违反用户协议 > 著作权/刑事**。个人自用、不分发、低频、不存密码，
风险相对可控；若要公开发布带登录的版本，先过律师。工程上建议做 feature flag 默认关、
只在本机 Keychain 存 token、日志不打 cookie/token、登录态失效回错误页 + 离线兜底。

## 时间线

| 日期 | 事件 |
|---|---|
| 2026-10-13/14 | linux.do 有第三方客户端反馈「批量接口 110001 → 改单集接口可用」 |
| 2026-11-04 | hongguo issue #1161：`multi_video_model/v1` 对匿名/签名/登录三种身份一律 200/0（判为服务端） |
| 2026-11-10 | 1.0.26 仍复现；多个第三方客户端报「获取不到播放地址」 |
| 2026-11-14 | hongguo issue #1422：登录态/游客态都 200/0 |
| 2026-11-15 | 本 App 仍可播（stream 走 shortplay 通道） |
| 2026-11-16 | shortplay 也开始 200/0；本文复现；hongguo issue #1432 仍在追问 |

## 附录：以后怎么快速复查

1. 用本机核心注册一个设备，直接打上面几条路由（真实签名或带 `X-TT-Token` 的登录态），
   看是否还是 `200 + 0 字节`；
2. 若为空，再对比一次 `video_detail`（应该正常）确认是播放口子而非全站故障；
3. 若某天 `player/v1` 匿名恢复，本仓库内核改回 `stream` 主通道即可，不需要其它改动；
4. 若要验证「登录态假设」，需要一个真实红果账号：在官方 App 抓一次 `X-TT-Token` 重放即可
   （注意脱敏，不要把 token 写进仓库/日志）。
