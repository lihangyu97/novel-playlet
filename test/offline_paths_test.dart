import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/storage/offline/offline_paths.dart';

/// S2：离线路径在实例内只解析一次——每次切集都走 path_provider 平台通道
/// （还会顺手 mkdir）是纯浪费。
void main() {
  test('root / videoDir / seriesDir 共用同一次 root 解析', () async {
    var calls = 0;
    final paths = OfflinePaths(
      rootDirectory: () async {
        calls += 1;
        return Directory.systemTemp;
      },
    );

    await paths.root();
    await paths.videoDir();
    await paths.seriesDir('series-1');
    await paths.novelDir();
    await paths.bookDir('book-1');

    expect(calls, 1);
  });
}
