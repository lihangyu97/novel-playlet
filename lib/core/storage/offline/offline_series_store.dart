import 'dart:convert';
import 'dart:io';

import '../../../data/models/chapter.dart';
import 'offline_paths.dart';
import 'offline_book.dart';
import 'offline_series.dart';

/// 短剧离线区：manifest + 明文 mp4。
///
/// 与小说区同构，但文件是二进制：下载器先用 [partFile] 拿到暂存路径，用
/// `IOSink` 流式写入（不把整集读进内存），完成后 [commitEpisode] 原子 rename
/// 成正式文件。见 docs/implementation.md。
///
/// 与自动层（内核 `backend/src/` 的 CENC 临时缓存）物理隔离；这里的内容只由
/// 用户显式删除。
class OfflineSeriesStore {
  OfflineSeriesStore({OfflinePaths? paths, int? capBytes})
    : _paths = paths ?? OfflinePaths(),
      capBytes = capBytes ?? videoCapBytes;

  /// 短剧离线区软上限（3 GiB）。
  static const int videoCapBytes = 3 * 1024 * 1024 * 1024;

  /// 本区实际软上限；测试注入小值来验证「下到一半触顶暂停」。
  final int capBytes;

  static const String manifestName = 'series.json';

  final OfflinePaths _paths;

  /// 读 manifest；没有/schema 不匹配/损坏都返回 null。
  Future<OfflineSeries?> read(String seriesId) async {
    if (seriesId.isEmpty) return null;
    try {
      final file = File(
        '${(await _paths.seriesDir(seriesId)).path}/$manifestName',
      );
      if (!await file.exists()) return null;
      return OfflineSeries.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// 开始一个整剧任务：写完整 manifest（集列表 + 元信息）。
  Future<void> begin(OfflineSeries series) async {
    final directory = await ensureDirectory(
      await _paths.seriesDir(series.seriesId),
    );
    await writeJsonAtomically(
      File('${directory.path}/$manifestName'),
      series.toJson(),
    );
  }

  /// 进度防抖落盘（暂停 / 完成 / 取消 / 每 30s 调用一次）。
  Future<void> saveManifest(OfflineSeries series) => begin(series);

  /// 一集正式文件的路径（`<episodeKey>.mp4`，不保证存在）。
  ///
  /// 与 [episodeFile] 的区别：这个只算路径（给写入/校正用），返回值不可空。
  Future<File> episodeFilePath(String seriesId, String episodeId) async => File(
    '${(await _paths.seriesDir(seriesId)).path}/${encodeOfflineKey(episodeId)}.mp4',
  );

  /// 已缓存集的文件；未缓存/坏文件返回 null。
  ///
  /// 播放器用这个判断"离线命中 → `VideoPlayerController.file`"，未命中走在线
  /// 流程（见 docs/implementation.md）。
  Future<File?> episodeFile(String seriesId, String episodeId) =>
      episodeFileIfCached(seriesId, episodeId);

  /// 一集的暂存文件路径（`<episodeKey>.mp4.part`）；下载器流式写入这里，
  /// 完成后 [commitEpisode] rename。目录不存在时创建。
  Future<File> partFile(String seriesId, String episodeId) async {
    final directory = await ensureDirectory(await _paths.seriesDir(seriesId));
    return File('${directory.path}/${encodeOfflineKey(episodeId)}.mp4.part');
  }

  /// 已缓存且非空（0 字节 mp4 视为坏文件）。
  Future<bool> hasEpisode(String seriesId, String episodeId) async {
    try {
      final file = await episodeFilePath(seriesId, episodeId);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 已缓存集的文件；未缓存/坏文件返回 null（播放器据此走在线流程）。
  Future<File?> episodeFileIfCached(String seriesId, String episodeId) async {
    try {
      final file = await episodeFilePath(seriesId, episodeId);
      // 一次 stat 同时判断存在与大小（exists + length 是两次 syscall）。
      final stat = await file.stat();
      return stat.size > 0 ? file : null;
    } catch (_) {
      // stat 失败包含「不存在」与权限错误，都按 miss 处理。
      return null;
    }
  }

  /// 把 [partFile] 原子 rename 成正式文件。
  ///
  /// [bytes] 由下载器在流式写入时统计（用于 manifest 进度）。
  Future<void> commitEpisode(
    String seriesId,
    String episodeId, {
    required int bytes,
  }) async {
    final part = await partFile(seriesId, episodeId);
    if (!await part.exists()) {
      throw FileSystemException('episode part file missing', part.path);
    }
    final target = await episodeFilePath(seriesId, episodeId);
    await part.rename(target.path);
    // 以磁盘实际大小为准校验：0 字节文件视为坏文件，删掉并按失败处理。
    // [bytes] 是下载器流式累计值，仅供 manifest 进度；磁盘长度更可信。
    final actual = await target.length();
    if (actual <= 0) {
      await deleteQuietly(target);
      throw const FileSystemException('episode file empty after commit');
    }
  }

  /// 删除某一集的暂存文件（重试/取消时清理）。
  Future<void> deletePart(String seriesId, String episodeId) async {
    await deleteQuietly(await partFile(seriesId, episodeId));
  }

  /// 按"正式文件是否存在"找缺口（断点续传的唯一依据）。
  Future<List<String>> missingEpisodeIds(
    String seriesId,
    List<Chapter> episodes,
  ) async {
    final missing = <String>[];
    for (final episode in episodes) {
      if (episode.id.isEmpty) continue;
      if (!await hasEpisode(seriesId, episode.id)) missing.add(episode.id);
    }
    return missing;
  }

  /// 短剧列表（只读 manifest，不扫盘）。
  Future<List<OfflineSeriesSummary>> summaries() async {
    final out = <OfflineSeriesSummary>[];
    for (final directory in await listChildDirectories(
      await _paths.videoDir(),
    )) {
      final series = await _readFromDirectory(directory);
      if (series != null) out.add(OfflineSeriesSummary.fromSeries(series));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 按文件存在校正 episodes[].cached/bytes 与 completed/bytes。
  ///
  /// 缓存中心/恢复任务时调用；比小说多一步：把每集的实际文件大小写回 manifest。
  ///
  /// [cleanupParts] 为 false 时不做收尾的 `.part` 清理：缓存中心进页扫盘时
  /// 可能刚好有本剧任务被「继续/重试」启动，下载器正在写同一个 `.part`
  /// （P1-1）。整区 `.part` 清理只留在启动恢复 [_restore] 与删除单条
  /// （目录整体删除）这类确定无任务的路径。
  Future<void> reconcile(String seriesId, {bool cleanupParts = true}) async {
    final series = await read(seriesId);
    if (series == null) return;
    final directory = await _paths.seriesDir(seriesId);
    final episodes = <OfflineEpisode>[];
    var completed = 0;
    var bytes = 0;
    for (final episode in series.episodes) {
      final file = File(
        '${directory.path}/${encodeOfflineKey(episode.id)}.mp4',
      );
      try {
        if (await file.exists() && await file.length() > 0) {
          final size = await file.length();
          completed += 1;
          bytes += size;
          episodes.add(episode.copyWith(bytes: size, cached: true));
          continue;
        }
      } catch (_) {
        // stat 失败按未缓存处理。
      }
      episodes.add(episode.copyWith(bytes: 0, cached: false));
    }
    await saveManifest(
      series.copyWith(
        episodes: episodes,
        completed: completed,
        bytes: bytes,
        updatedAt: DateTime.now(),
      ),
    );
    if (cleanupParts) await _deletePartFiles(directory);
  }

  /// 删除一部剧的离线内容（调用方负责先取消进行中的任务）。
  Future<void> delete(String seriesId) async {
    if (seriesId.isEmpty) return;
    await deleteDirectoryQuietly(await _paths.seriesDir(seriesId));
  }

  /// 清空整个短剧离线区（不影响小说区）。
  Future<void> clearAll() async {
    await deleteDirectoryQuietly(await _paths.videoDir());
  }

  /// 短剧区统计：只累加 manifest 的 bytes（列表页不扫盘）。
  Future<OfflineStats> stats() async {
    var count = 0;
    var bytes = 0;
    for (final directory in await listChildDirectories(
      await _paths.videoDir(),
    )) {
      final series = await _readFromDirectory(directory);
      if (series == null) continue;
      count += 1;
      bytes += series.bytes;
    }
    return OfflineStats(count: count, bytes: bytes, capBytes: capBytes);
  }

  /// 清理没有 manifest 的孤立目录与残留 `.part` 文件；返回删除的目录数。
  ///
  /// [cleanupParts] 为 false 时只删孤立目录、不碰正常目录里的 `.part`：
  /// 缓存中心进页时下载器可能正在写盘，删 `.part` 会让当前集从 0 重下
  /// （P1-1）。孤立目录本身不可能有活动任务——下载器一定先写 manifest 再
  /// 落文件。
  Future<int> pruneOrphans({bool cleanupParts = true}) async {
    var removed = 0;
    for (final directory in await listChildDirectories(
      await _paths.videoDir(),
    )) {
      final series = await _readFromDirectory(directory);
      if (series == null) {
        await deleteDirectoryQuietly(directory);
        removed += 1;
        continue;
      }
      if (cleanupParts) await _deletePartFiles(directory);
    }
    return removed;
  }

  Future<OfflineSeries?> _readFromDirectory(Directory directory) async {
    try {
      final file = File('${directory.path}/$manifestName');
      if (!await file.exists()) return null;
      return OfflineSeries.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// 清理离线区里残留的 `.part` 文件（半截 mp4 / 原子写临时文件）。
  ///
  /// 启动恢复时调用；孤立目录由缓存中心的 [pruneOrphans] 处理。
  Future<void> cleanupPartFiles() async {
    await _deletePartFiles(await _paths.videoDir(), recursive: true);
  }

  Future<void> _deletePartFiles(
    Directory directory, {
    bool recursive = false,
  }) async {
    try {
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('.part')) {
          await deleteQuietly(entity);
        }
      }
    } catch (_) {
      // 清理失败留给下次。
    }
  }
}
