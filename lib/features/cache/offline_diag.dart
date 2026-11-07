import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 离线下载诊断日志（诊断短剧/小说下载失败用）。
///
/// release 包没有控制台、iOS 也没有可读 logcat，失败原因如果只存在内存里就
/// 再也拿不到了。这里把「开始/失败/暂停」等关键事件追加到
/// `<AppSupport>/offline/diag.log`（超过 [maxBytes] 轮转一次），排查时可以直接
/// 从设备容器把文件取出来。**只记事件与错误文本，不记正文内容**。
///
/// 所有写盘失败都静默：诊断日志不能反过来影响下载本身。
const int offlineDiagMaxBytes = 128 * 1024;

Future<File?> _diagFile() async {
  try {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/diag.log');
  } catch (error) {
    debugPrint('[offline-diag] open failed: $error');
    return null;
  }
}

/// 追加一条带时间戳的诊断事件（失败静默）。
Future<void> offlineDiag(String event) async {
  final file = await _diagFile();
  if (file == null) return;
  try {
    if (await file.exists() && await file.length() > offlineDiagMaxBytes) {
      final rotated = File('${file.path}.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    final now = DateTime.now().toIso8601String();
    await file.writeAsString('$now $event\n', mode: FileMode.append);
  } catch (error) {
    debugPrint('[offline-diag] write failed: $error');
  }
}
