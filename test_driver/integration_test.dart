import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// `flutter drive --profile` 的驱动：把 integration_test 的 reportData
/// （阅读页分页/切章的帧耗时采集结果）落盘成 JSON，方便直接看数字。
///
/// 用法：
///   flutter drive --profile -d `<iPhone UDID>` \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/reader_pagination_perf_test.dart
///
/// 结果写到 build/reader_pagination_perf.json。
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) return;
    final file = File('build/reader_pagination_perf.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    stdout.writeln('PERF JSON -> ${file.absolute.path}');
  },
);
