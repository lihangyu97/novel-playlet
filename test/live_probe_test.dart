import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/src/rust/frb_generated.dart';

/// 真实上游探针（不是断言测试，是抓真实结构用）。
///
/// 在 macOS host 上直接加载 `rust/target/debug/libfqapi_core.dylib`，用真实
/// 设备池注册 + 真实网络，把推荐/详情/目录/正文四步的原始 JSON 落盘到
/// `.probe/`，供解析器按真实字段形状实现。
///
/// 运行：`flutter test test/live_probe_test.dart --reporter expanded`
void main() {
  final dylib = 'rust/target/debug/libfqapi_core.dylib';
  final outDir = Directory('.probe');

  final enabled = Platform.environment['LIVE_PROBE'] == '1';
  test(
    'live probe: recommend -> detail -> directory -> chapter',
    skip: enabled ? null : 'manual: LIVE_PROBE=1 flutter test test/live_probe_test.dart',
    () async {
    if (!File(dylib).existsSync()) {
      fail('host core missing: $dylib');
    }
    if (!outDir.existsSync()) outDir.createSync();

    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib));
    BackendTransport.markRuntimeReady();

    final root = Directory.systemTemp.createTempSync('novel_playlet_probe');
    final configDir = Directory('${root.path}/config')..createSync();
    File('assets/config/config.json').copySync('${configDir.path}/config.json');
    File(
      'assets/config/filter.json',
    ).copySync('${configDir.path}/filter.json');
    final poolFile = File('${configDir.path}/device_pool.json');
    File(
      'assets/config/device_pool.example.json',
    ).copySync(poolFile.path);

    final transport = BackendTransport(port: 0); // 0 = 内核自选端口
    final started = await transport.start(
      configPath: '${configDir.path}/config.json',
      poolPath: poolFile.path,
      filterPath: '${configDir.path}/filter.json',
      runtimeDir: root.path,
    );
    // ignore: avoid_print
    print('[probe] core started: $started baseUrl=${transport.baseUrl}');

    Future<String> get(String path, [String query = '']) async {
      final started = DateTime.now();
      final r = await transport.send('GET', path, query: query);
      // ignore: avoid_print
      print(
        '[probe] GET $path?$query -> ${r.statusCode} '
        '${DateTime.now().difference(started).inMilliseconds}ms '
        '${r.body.length}B',
      );
      return r.text;
    }

    void save(String name, String body) {
      File('${outDir.path}/$name.json').writeAsStringSync(body);
    }

    // 1) 推荐流（tab_type=2 就是书城小说推荐）。
    final recommend = await get(
      '/api/v1/recommend/homepage',
      'tab_type=2&offset=0&tab_index=0',
    );
    save('10-recommend', recommend);

    // 2) 搜索。
    final search = await get(
      '/api/v1/search',
      'query=${Uri.encodeQueryComponent('斗罗')}&tab_type=2&offset=0&count=10',
    );
    save('20-search', search);

    // 3) 从两份响应里找候选作品 id（不知道确切形状，先扫一遍）。
    final ids = <String>{};
    void scan(Object? node, String key) {
      if (node is Map) {
        for (final entry in node.entries) {
          final k = entry.key.toString();
          final v = entry.value;
          final looksId = k == 'book_id' || k == 'bookId' || k == 'item_id' ||
              k == 'itemId' || k == 'id';
          if (looksId && v is String && v.length >= 6) {
            ids.add('$k=$v');
          }
          scan(v, k);
        }
      } else if (node is List) {
        for (final item in node) {
          scan(item, key);
        }
      }
    }

    for (final body in [recommend, search]) {
      try {
        scan(jsonDecode(body), '');
      } catch (_) {}
    }
    // ignore: avoid_print
    print('[probe] id candidates(${ids.length}): ${ids.take(12).join(', ')}');

    // 4) 详情 + 目录 + 正文：用推荐响应里最可能的 book_id 逐个试。
    final bookIds = ids
        .where((e) => e.startsWith('book_id='))
        .map((e) => e.substring('book_id='.length))
        .toList();
    for (final id in bookIds.take(3)) {
      try {
        final detail = await get('/api/v1/books/$id/detail');
        save('30-detail-$id', detail);
        final directory = await get('/api/v1/books/$id/directory');
        save('40-directory-$id', directory);

        // 目录里找第一个章节 id。
        final dj = jsonDecode(directory) as Map<String, dynamic>;
        String? chapterId;
        void findChapter(Object? node) {
          if (chapterId != null) return;
          if (node is Map) {
            for (final entry in node.entries) {
              final k = entry.key.toString();
              final v = entry.value;
              if (v is String &&
                  v.length >= 6 &&
                  (k == 'item_id' || k == 'itemId' || k == 'chapter_id')) {
                chapterId = v;
                return;
              }
              findChapter(v);
            }
          } else if (node is List) {
            for (final item in node) {
              findChapter(item);
            }
          }
        }

        findChapter(dj['data']);
        // ignore: avoid_print
        print('[probe] first chapter of $id: $chapterId');
        if (chapterId != null) {
          final novel = await get(
            '/api/v1/chapters/${Uri.encodeComponent(chapterId!)}/novel',
          );
          save('50-chapter-novel', novel);
          final plain = await get('/api/v1/chapters/${Uri.encodeComponent(chapterId!)}');
          save('51-chapter-plain', plain);
        }
        break;
      } catch (error) {
        // ignore: avoid_print
        print('[probe] book $id failed: $error');
      }
    }

    await transport.stop();
    // ignore: avoid_print
    print('[probe] artifacts in ${outDir.absolute.path}');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
