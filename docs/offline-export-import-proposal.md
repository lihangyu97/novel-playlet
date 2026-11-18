# 离线内容导出 / 导入评估

> 状态：**只评估、未实现**（2026-11-18）
> 结论速览：**视频 → mp4 技术成本≈0**（磁盘上就是明文 mp4）；**小说 → txt 便宜**；
> **小说 ← txt 贵在「本地书身份」，不贵在「转 JSON」**（转 JSON 只占约 10%）。
> 相关代码：[offline_series_store.dart](../lib/core/storage/offline/offline_series_store.dart)、
> [offline_book_store.dart](../lib/core/storage/offline/offline_book_store.dart)、
> [offline_downloader.dart](../lib/features/cache/offline_downloader.dart)、
> [video.rs](../rust/src/endpoints/video.rs)。

## 1. 结论

| 需求 | 成本（人天） | 风险 | 卡点 |
|---|---|---|---|
| 视频 → mp4（单集最小可用） | 0.5 | 低 | 交付方式（见 §3） |
| 视频 → mp4（整剧 + 进度 + 命名） | 1.5–2 | 中 | 大文件复制、磁盘翻倍、iOS 后台被杀 |
| 小说 → txt | 0.5–1 | 低 | 同为交付方式 |
| 小说 ← txt（MVP：导入能读，评论/缓存按钮先不管） | 1 | 中 | 章节切分歧义 |
| 小说 ← txt（可交付完整版） | 2.5–4 | 中高 | 本地书身份要在全链路改，清空缓存会误删 |

一句话：**导出是「把已经正确的文件搬出去」，导入是「凭空造一本上游不存在的书」**。前者只是 I/O，
后者要处理一个现在不存在的内容域。

## 2. 视频导出为什么几乎免费

`offline/video/<b64url(seriesId)>/<b64url(episodeId)>.mp4` **本来就是一个标准明文 mp4**
（[§6.1 清单](implementation.md)、[episodeFilePath](../lib/core/storage/offline/offline_series_store.dart#L63-L65)）。
证据链：

1. 内核缓存（`backend/src/`）存的是上游原始字节，CENC 源就是密文，
   [download_and_save](../rust/src/endpoints/video.rs#L1734-L1750) 明确"按下载时的字节落盘"。
2. 离线下载器**不碰上游**，它拿的是回环 `/src/...` 的明文流：
   [videoSource → openVideoStream](../lib/features/cache/offline_downloader.dart#L824-L849)，
   边收边写 `.part`，完成后原子 rename 成 `.mp4`（[commitEpisode](../lib/core/storage/offline/offline_series_store.dart#L107-L120)）。
3. `/src` 服务端做**长度保持**的容器重写：`encv→hvc1`、`enca→mp4a`、`sinf→free`
   （[video.rs#L3869-L3880](../rust/src/endpoints/video.rs#L3869-L3880)），所以落盘文件是
   **自洽**的（容器不再声明加密，样本已解密），不依赖回环二次处理。
   **整文件 GET 也走同一条路径**，不是只有 Range 请求才重写。
4. 缓存条目都是 faststart（ftyp + moov 在前，[video.rs#L1957](../rust/src/endpoints/video.rs#L1957)），
   拖进 QuickTime / 上传都能直接起播。
5. 反证：App 自己的离线播放就是 `VideoPlayerController.file`
   （[video_player_page.dart#L49](../lib/features/video/video_player_page.dart#L49)）。它能播，
   外部播放器就能播。

**所以导出 = `File.copy` + 改名 + 交付**，不需要 ffmpeg、不需要 remux。

## 3. 视频导出的真实成本

技术成本在四周，不在转码：

### 3.1 交付方式（唯一的真卡点）

`Info.plist` 现在没有 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`，
`Documents/` 对用户不可见，所以"写进沙盒就能拿走"不成立。两条路：

| 方案 | 成本 | 代价 |
|---|---|---|
| **A. 加 `share_plus`** | 0.5d | 要走 [CONTRACTS.md](../CONTRACTS.md#L29) 依赖白名单；系统分享面板可直接「存到文件」/隔空投送/微信 |
| **B. 零依赖**：拷到 `Documents/Exports/` + Info.plist 开两个 key | 2h | **要改 `ios/`**（契约里禁止）；用户体验绕一层「文件 App → 我的 iPhone → 摆烂盒子」 |

建议 A。B 可作为 A 之前的当天可验证手段。

### 3.2 其余

- **命名**：文件名是 `b64url(episodeId)`，要按 `series.json` 的剧名 + `index` 映射成
  `剧名-第01集.mp4`。0.2d。
- **磁盘**：导出是复制，峰值 2×；短剧区软上限 3 GiB
  （[videoCapBytes](../lib/core/storage/offline/offline_series_store.dart#L23)），
  导出前必须校验剩余空间，否则写到一半 disk full。
- **大文件/后台**：iOS 复制几百 MB 时切后台会被挂起，需要前台保活 + 进度 + 可取消 + 失败清理临时文件。
  这是 0.5–1d 的主要来源。
- **非 mp4 源**：`video_url_extension` 会保留 `.m4s` / `.ts`
  （[video.rs#L1896-L1910](../rust/src/endpoints/video.rs#L1896-L1910)），但离线区一律命名 `.mp4`
  （[episodeFilePath](../lib/core/storage/offline/offline_series_store.dart#L63-L65)）。
  这类文件可能不是标准容器。导出时读偏移 4 的 `ftyp` 判定即可，不合格就跳过并提示。真实占比很低。

## 4. 小说 → txt

章节 JSON 的 `paragraphs` 是**已清洗的纯文本数组**
（[writeChapter](../lib/core/storage/offline/offline_book_store.dart#L103-L116)），
`book.json` 有有序章节表和卷名（[toJson](../lib/core/storage/offline/offline_book.dart#L114-L126)）。

导出 = 按 manifest 顺序拼字符串：章标题 + 段落 + 空行，卷名做分隔。要处理的只有：

- 缺章（`completed < total`）跳过还是提示——建议在文件名或首行标注「缺 N 章」；
- UTF-8 BOM（照顾 Windows 记事本的旧行为）；
- 段落本身可能含 `\n`（少见，清洗后一般是单段），需要归一。

**成本 0.5–1d**，与视频导出共用交付层。

## 5. 小说 ← txt：贵在哪

### 5.1 要落成的格式（这一步确实便宜）

导入的产物就是现有格式，不需要改 schema：

```jsonc
// offline/novel/<b64url(bookId)>/book.json
{ "schema": 1, "kind": "novel", "bookId": "local:<hash>", "title": "书名", "cover": "",
  "chapters": [{ "id": "local:<hash>:c0", "title": "第一章 …", "volumeName": "", "index": 0 }],
  "completed": 1200, "total": 1200, "bytes": 0, "createdAt": 0, "updatedAt": 0 }

// offline/novel/<bookKey>/<b64url(chapterId)>.json
{ "v": 2, "id": "local:<hash>:c0", "title": "第一章 …",
  "paragraphs": ["段落 1", "段落 2"], "paraIndices": [null, null], "fetchedAt": 0 }
```

`paraIndices` 写全 `null` 是有意的（不是省事）：纯文本源就是"全 null 列表"
（[ChapterContent.paraIndices 注释](../lib/data/models/chapter_content.dart#L31-L37)），
这样 `hasAnchors` 为假、`paraIndices.isEmpty` 为假，阅读器**不会**为每章去补取网络锚点
（[reader_controller.dart#L424](../lib/features/reader/reader_controller.dart#L424)）。

### 5.2 四块成本

| 块 | 成本 | 内容 |
|---|---|---|
| 选文件 | 0.5d | 需要 `file_picker`（iOS 走 UIDocumentPicker）或自写平台 channel |
| 编码 | 0.5d | 中文 txt 大量是 GBK/GB18030，Dart 原生只认 UTF-8。纯 Dart `fast_gbk` 或原生 `charset_converter`；策略：UTF-8 严格解码 → 失败回退 GBK → 再失败按 latin1 兜底并提示 |
| 切章 + 写 JSON | 0.5d | 正则识别 `第X章/节/回/卷`、`Chapter N`、`序章/楔子/尾声`；识别不到就按字数（如 3000 字）硬切并标注「自动分章」。**§5.1 就是这一步的全部产出** |
| **本地书身份** | **1–2d** | 见 §5.3，真正的成本 |

### 5.3 本地书身份：现在全 App 假设 `bookId` 能回源

合成的 `bookId` 进不了上游，下面每一条都要单独处理，漏一条就是"每章白打一次请求"或"不能用的按钮"：

1. **锚点补取**：`paraIndices` 为空就每章补取一次网络正文
   （[reader_controller.dart#L424](../lib/features/reader/reader_controller.dart#L424)、[#L439](../lib/features/reader/reader_controller.dart#L439)）。
   §5.1 的全 null 写法能免掉，但这是"用例刚好契合"，不是显式规则——建议同时按 `origin` 显式跳过，别依赖巧合。
2. **后台刷目录**：进阅读页会 `api.directory(bookId)`
   （[#L291](../lib/features/reader/reader_controller.dart#L291)），本地书必然失败。失败是静默的，但每次进书一发请求，
   在**上游 40 次/分**的限流下是纯损耗。
3. **详情页**：已有离线兜底（[detail_providers.dart#L53-L56](../lib/features/detail/detail_providers.dart#L53-L56)），
   能渲染目录和书名；但「缓存小说」按钮（`OfflineDownloadButton`）会拿合成 id 去下载，必然报错，要隐藏。
4. **评论/段评**：阅读页工具栏的「评论」、段评气泡都依赖真 `chapterId` + `version`，本地书要禁用（不是"能点但空"）。
5. **清空缓存会误删**：缓存中心的「清空小说缓存」直接 `clearAll()`
   （[cache_center_page.dart#L354-L390](../lib/features/cache/cache_center_page.dart#L354-L390)），
   导入的书如果放在 `offline/novel/` 下会被一起删。两个解法：
   - **A（推荐）**：另开 `imported/novel/` 区，缓存中心不管理它，删除入口放在「我的 → 书架」条目上；
   - B：manifest 加可选 `origin: "import"` 字段，清空时跳过——加字段是向后兼容的（老解析器忽略未知键），
     不用动 `offlineSchema`，但清空逻辑要变成逐条判断，成本更高。
6. **重复导入 / 去重**：`bookId` 用「文件名 + 字节数 + 内容哈希」派生，同文件二次导入直接提示已存在。
7. **书架 / 进度 / WebDAV**：都走合成 id，技术上可行（`NovelItem.isValid` 只要求 id + title
   （[novel_item.dart#L43](../lib/data/models/novel_item.dart#L43)），封面空由 `NovelCover` 兜底）。
   要定的是**导入的书要不要进云同步**——进了云端，另一台设备只有一条书架记录、没有正文，点开会失败。
   建议：同步记录里带 `origin`，没有正文的设备提示「本地书，请在本机导入」。

## 6. 成本汇总

| 需求 | 最小可用 | 可交付完整版 | 关键依赖 |
|---|---|---|---|
| 视频 → mp4（单集） | 0.5d | 1d | `share_plus`（或 Info.plist） |
| 视频 → mp4（整剧） | — | +1d | 进度/取消/空间校验 |
| 小说 → txt | 0.5d | 1d | 同上 |
| 小说 ← txt | 1d | 2.5–4d | `file_picker` + 编码库 |

导出侧（视频单集 + 整剧 + 小说 txt）合计 **2–3 人天**，且共用一套交付层，属于低风险高收益。
导入侧单独 **1–4 人天**，风险集中在身份扩散和误删。

## 7. 建议路径

1. **第一步（2–3d）**：交付层 + 视频导出（单集/整剧）+ 小说导出 txt。
   一次性解决"我的内容能不能带走"，风险最低。
2. **第二步（1d，MVP）**：txt 导入，且**导入的书 = 只读本地书**：
   独立 `imported/novel/` 区、不进缓存统计、详情页只给「阅读」、隐藏缓存/评论、
   阅读页跳过刷目录与锚点补取。先验证有没有真实需求。
3. **第三步（可选）**：手动修正分章、编码选择、分卷、批量导入、导出为 epub。
   这些才是把 1d 拖到 4d 的部分，等有需求再做。

## 8. 待拍板

- [ ] 交付方式走 **A（`share_plus`，进白名单）** 还是 **B（改 `ios/Info.plist`，零依赖）**？
- [ ] 导入的书是否允许进 WebDAV 同步（决定要不要加 `origin` 字段与跨设备提示）？
- [ ] 导入区独立（`imported/novel/`）还是复用 `offline/novel/` 加 `origin` 标记？
- [ ] 导出是否需要"整剧打包 zip"（要加 `archive` 依赖）？建议先不做。

## 9. 验收标准（实现时）

- 导出的 `.mp4` 能被系统「文件」App 预览、能隔空投送到 Mac 用 QuickTime 播放；
- 导出的 `.txt` 用 Windows 记事本和 VS Code 打开都不乱码（BOM + UTF-8）；
- 导入 3000 章、30 MB 的 GBK txt：进度可见、可取消、失败不留半截目录；
- 导入的书打开后**不产生任何上游请求**（用 `offline/diag.log` 或内核 `rust.log` 核对）；
- 「清空小说缓存」后导入的书仍在；
- 重复导入同一文件给出明确提示，不产生第二份副本。
