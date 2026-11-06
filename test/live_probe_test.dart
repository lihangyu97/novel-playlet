import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/src/rust/frb_generated.dart';

/// 真实上游验证（手动跑，不进 CI）。
///
/// 在 macOS host 上加载 `rust/target/debug/libfqapi_core.dylib`，用真实设备
/// 注册 + 真实网络跑完整链路，并把每一步**解析后**的结果打印出来：解析器
/// 是否跟得上上游字段变化，只有这里能发现。
///
/// 运行：`LIVE_PROBE=1 flutter test test/live_probe_test.dart --reporter expanded`
void main() {
  final enabled = Platform.environment['LIVE_PROBE'] == '1';
  final dylib = 'rust/target/debug/libfqapi_core.dylib';

  test('live: recommend -> search -> detail -> directory -> chapter', skip: enabled ? null : 'manual: LIVE_PROBE=1 flutter test test/live_probe_test.dart', () async {
    if (!File(dylib).existsSync()) {
      fail(
        'host core missing: $dylib（先跑 cargo build --manifest-path rust/Cargo.toml）',
      );
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib));
    BackendTransport.markRuntimeReady();

    final root = Directory.systemTemp.createTempSync('novel_playlet_live');
    final configDir = Directory('${root.path}/config')..createSync();
    File('assets/config/config.json').copySync('${configDir.path}/config.json');
    File('assets/config/filter.json').copySync('${configDir.path}/filter.json');
    final poolFile = File('${configDir.path}/device_pool.json');
    File('assets/config/device_pool.example.json').copySync(poolFile.path);

    final transport = BackendTransport(port: 0);
    await transport.start(
      configPath: '${configDir.path}/config.json',
      poolPath: poolFile.path,
      filterPath: '${configDir.path}/filter.json',
      runtimeDir: root.path,
    );
    final api = ApiClient(transport);
    final stopwatch = Stopwatch()..start();

    // 1) 推荐流
    final recommend = await api.recommend();
    final session = recommend.sessionId ?? '';
    // ignore: avoid_print
    print(
      '[推荐] ${recommend.items.length} 本, nextOffset=${recommend.nextOffset}, '
      'session=${session.length > 8 ? '${session.substring(0, 8)}…' : session} '
      '${stopwatch.elapsedMilliseconds}ms',
    );
    // ignore: avoid_print
    print(
      '[推荐] 前 5: ${recommend.items.take(5).map((i) => '${i.title}(${i.author})').join(' | ')}',
    );
    expect(recommend.items, isNotEmpty, reason: '推荐流解析为空');

    // 2) 翻页
    if (recommend.nextOffset != null) {
      final page2 = await api.recommend(
        offset: recommend.nextOffset!,
        sessionId: recommend.sessionId,
      );
      final firstIds = recommend.items.map((i) => i.id).toSet();
      final overlap = page2.items.where((i) => firstIds.contains(i.id)).length;
      // ignore: avoid_print
      print(
        '[推荐·第2页] ${page2.items.length} 本, 与第1页重复 $overlap 本, '
        'next=${page2.nextOffset}',
      );
    } else {
      // 即使上游声明 has_more=false，也探一次 offset=2：确认游标语义是
      // "页码"还是"无效字段"，避免把可翻页的流误判成只有一页。
      final probe = await api.recommend(
        offset: 2,
        sessionId: recommend.sessionId,
      );
      final firstIds = recommend.items.map((i) => i.id).toSet();
      final overlap = probe.items.where((i) => firstIds.contains(i.id)).length;
      // ignore: avoid_print
      print(
        '[推荐·offset=2] ${probe.items.length} 本, 与第1页重复 $overlap 本（判断游标是否有效）',
      );
    }

    // 3) 搜索（书名关键词）
    final search = await api.search('斗罗');
    // ignore: avoid_print
    print('[搜索] ${search.items.length} 本, next=${search.nextOffset}');
    // ignore: avoid_print
    print(
      '[搜索] 前 5: ${search.items.take(5).map((i) => '${i.title}(${i.author})').join(' | ')}',
    );
    expect(search.items, isNotEmpty, reason: '搜索结果解析为空');

    // 4) 详情
    final bookId = recommend.items.first.id;
    final detail = await api.bookDetail(bookId);
    // ignore: avoid_print
    print(
      '[详情] ${detail.title} / ${detail.author} / ${detail.metaParts.join(' · ')} / '
      '评分 ${detail.score} / ${detail.readLabel} / 目录 ${detail.serialCount} 章',
    );
    // ignore: avoid_print
    print('[详情] 标签 ${detail.tags} 更新至 ${detail.lastChapterTitle}');
    expect(detail.title, isNotEmpty, reason: '详情解析为空');

    // 5) 目录
    final chapters = await api.directory(bookId);
    // ignore: avoid_print
    print(
      '[目录] ${chapters.length} 章, 首章 "${chapters.first.title}" '
      '卷 "${chapters.first.volumeName}", ID=${chapters.first.id}',
    );
    expect(chapters, isNotEmpty, reason: '目录解析为空');

    // 6) 正文（图文接口 + 回退）
    final chapter = await api.chapter(
      chapters.first.id,
      title: chapters.first.title,
    );
    // ignore: avoid_print
    print(
      '[正文] "${chapter.title}" ${chapter.paragraphs.length} 段 / '
      '${chapter.paragraphs.fold<int>(0, (sum, p) => sum + p.length)} 字',
    );
    // ignore: avoid_print
    print('[正文] 开头: ${chapter.paragraphs.take(3).join(' / ')}');
    // ignore: avoid_print
    print(
      '[正文] 结尾: ${chapter.paragraphs.last.substring(0, chapter.paragraphs.last.length.clamp(0, 40))}',
    );
    expect(chapter.paragraphs, isNotEmpty, reason: '正文解析为空');

    // 摘要留档，便于上游字段变化时对照
    final outDir = Directory('.probe')..createSync(recursive: true);
    File('${outDir.path}/parsed-summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'recommend': {
          'count': recommend.items.length,
          'nextOffset': recommend.nextOffset,
          'titles': recommend.items.take(5).map((i) => i.title).toList(),
        },
        'search': {
          'count': search.items.length,
          'titles': search.items.take(5).map((i) => i.title).toList(),
        },
        'detail': {
          'title': detail.title,
          'author': detail.author,
          'meta': detail.metaParts,
          'score': detail.score,
          'read': detail.readLabel,
          'tags': detail.tags,
        },
        'directory': {'count': chapters.length, 'first': chapters.first.title},
        'chapter': {
          'title': chapter.title,
          'paragraphs': chapter.paragraphs.length,
          'head': chapter.paragraphs.take(2).toList(),
        },
      }),
    );

    await transport.stop();
    // ignore: avoid_print
    print(
      '[完成] ${stopwatch.elapsedMilliseconds}ms，摘要写入 .probe/parsed-summary.json',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
