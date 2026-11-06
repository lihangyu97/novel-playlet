import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_playlet/app/providers.dart';
import 'package:novel_playlet/app/router.dart';
import 'package:novel_playlet/app/theme/app_theme.dart';
import 'package:novel_playlet/core/backend/backend_transport.dart';
import 'package:novel_playlet/data/api/api_client.dart';
import 'package:novel_playlet/features/reader/reader_controller.dart';
import 'package:novel_playlet/features/reader/reader_page.dart';

/// 阅读页分页/切章在**真机 profile 模式**下的 UI 线程帧耗时采集。
///
/// 背景（docs/architecture-review.md P1-6）：阅读页在 LayoutBuilder 里对整章
/// 所有段落跑 TextPainter，量完才画第一页。文档估计切章有 20–50ms 同步卡顿，
/// 但那是静态推断；TextPainter 必须在 UI isolate，widget 测试/模拟器都测不准，
/// 只能真机 profile 量。
///
/// 这份用例用合成数据（150 段/章、12 章）把「冷启动首章分页」和「连续切 10 次
/// 章」各量一遍，通过 FrameTiming 采集每帧的 build/raster 耗时，最后写进
/// integration_test 的 reportData（test_driver/integration_test.dart 落盘）。
///
/// 判定口径：iPhone 13 是 60Hz，帧预算 16.7ms；重点关注切章那一帧的
/// buildDuration（分页发生在 build/layout 阶段）。
///
/// 运行：
///   flutter drive --profile -d 00008110-001431393AC2801E \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/reader_pagination_perf_test.dart
///
/// 注意：这会临时用测试 runner 覆盖手机上的 App（同 bundle id），跑完需要用
/// 正常构建重新安装一次。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 性能采集要真实帧：fullyLive 让测试跑在真实帧调度上，而不是只在 pump 时出帧。
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('阅读页分页/切章帧耗时（真机 profile）', (tester) async {
    final runId = DateTime.now().millisecondsSinceEpoch;
    final args = ReaderArgs(
      bookId: 'perf-$runId',
      bookTitle: '性能样本',
      chapterId: 'perf-$runId-c1',
      chapterIndex: 0,
    );

    final transport = _PerfTransport(runId);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(transport))],
    );
    addTearDown(container.dispose);

    final timings = <FrameTiming>[];
    void onTimings(List<FrameTiming> batch) => timings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    addTearDown(
      () => SchedulerBinding.instance.removeTimingsCallback(onTimings),
    );

    Future<Map<String, Object?>> measure(
      String label,
      Future<void> Function() action,
    ) async {
      final start = timings.length;
      final wall = Stopwatch()..start();
      await action();
      wall.stop();
      // 真机 profile 下 FrameTiming 是引擎异步批量回调的，给它一点时间收尾。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final frames = timings.sublist(start);
      return _summarize(label, frames, wall.elapsed);
    }

    final results = <Map<String, Object?>>[];

    // 1) 冷启动：pumpWidget → 目录/正文回来 → 第一章整章分页 + 首帧。
    results.add(
      await measure('cold-open', () async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              home: ReaderPage(args: args),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }),
    );

    // 2) 预热一次切章（不计入统计，避免首帧的 JIT/缓存噪声）。
    final provider = readerSessionProvider(args);
    await tester.pumpAndSettle();
    container.read(provider.notifier).nextChapter();
    await tester.pumpAndSettle();

    // 3) 连续切 10 章：每次都是新正文 → 整章重新分页。
    for (var i = 1; i <= 10; i++) {
      results.add(
        await measure('switch-$i', () async {
          container.read(provider.notifier).nextChapter();
          await tester.pumpAndSettle();
        }),
      );
    }

    final session = container.read(provider);
    expect(session.contentIndex, 11, reason: '应连续切到第 12 章');
    expect(_PerfTransport.paragraphCount, greaterThan(0));

    binding.reportData = {
      'device': Platform.operatingSystemVersion,
      'profileMode': const bool.fromEnvironment('dart.vm.profile'),
      'paragraphsPerChapter': _PerfTransport.paragraphCount,
      'chapterCount': _PerfTransport.chapterCount,
      'frameBudgetMs': 1000 / 60,
      'results': results,
      'switchAggregate': _aggregate(
        results.where((r) => (r['label']! as String).startsWith('switch-')),
      ),
    };
  });
}

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------

Map<String, Object?> _summarize(
  String label,
  List<FrameTiming> frames,
  Duration wall,
) {
  final builds = [
    for (final frame in frames) frame.buildDuration.inMicroseconds / 1000,
  ];
  final rasters = [
    for (final frame in frames) frame.rasterDuration.inMicroseconds / 1000,
  ];
  final spans = [
    for (final frame in frames) frame.totalSpan.inMicroseconds / 1000,
  ];
  return _aggregateOf(
    label: label,
    builds: builds,
    rasters: rasters,
    spans: spans,
    wallMs: wall.inMicroseconds / 1000,
  );
}

Map<String, Object?> _aggregate(Iterable<Map<String, Object?>> results) {
  final builds = <double>[];
  final rasters = <double>[];
  final spans = <double>[];
  var wall = 0.0;
  for (final r in results) {
    builds.addAll((r['buildsMs']! as List).cast<double>());
    rasters.addAll((r['rastersMs']! as List).cast<double>());
    spans.addAll((r['spansMs']! as List).cast<double>());
    wall += r['wallMs']! as double;
  }
  return _aggregateOf(
    label: 'switch-all',
    builds: builds,
    rasters: rasters,
    spans: spans,
    wallMs: wall,
  );
}

Map<String, Object?> _aggregateOf({
  required String label,
  required List<double> builds,
  required List<double> rasters,
  required List<double> spans,
  required double wallMs,
}) {
  final sortedBuilds = List<double>.of(builds)..sort();
  final sortedSpans = List<double>.of(spans)..sort();
  final budget = 1000 / 60;
  return {
    'label': label,
    'frames': builds.length,
    'wallMs': _round(wallMs),
    'buildMs': {
      'p50': _round(_percentile(sortedBuilds, 0.50)),
      'p95': _round(_percentile(sortedBuilds, 0.95)),
      'max': _round(sortedBuilds.isEmpty ? 0 : sortedBuilds.last),
      'overBudgetFrames': builds.where((b) => b > budget).length,
    },
    'rasterMaxMs': _round(
      rasters.isEmpty ? 0 : (List<double>.of(rasters)..sort()).last,
    ),
    'totalSpanP95Ms': _round(_percentile(sortedSpans, 0.95)),
    'jankFrames': spans.where((s) => s > budget).length,
    // 原始逐帧数据留给后续分析（数量可控：十几次切章 × 十几帧）。
    'buildsMs': [for (final b in builds) _round(b)],
    'rastersMs': [for (final r in rasters) _round(r)],
    'spansMs': [for (final s in spans) _round(s)],
  };
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final index = (p * (sorted.length - 1)).round();
  return sorted[index];
}

double _round(double value) => (value * 100).round() / 100;

// ---------------------------------------------------------------------------
// 合成假后端：只服务目录 + 正文，避免真机 perf 采集依赖真实上游。
// ---------------------------------------------------------------------------

class _PerfTransport extends BackendTransport {
  _PerfTransport(this.runId) : super(port: 0);

  final int runId;

  static const chapterCount = 12;

  /// 每章段落数：默认 150（长章）；复核其他长度用
  /// `--dart-define=PERF_PARAGRAPHS=80`。
  static const paragraphCount = int.fromEnvironment(
    'PERF_PARAGRAPHS',
    defaultValue: 150,
  );

  /// 每段约 90–120 个汉字：足够撑出 9–10 页/章，且让 TextPainter 的排版成本
  /// 接近真实长章。内容固定，保证多次运行可比。
  static final _paragraph = [
    '陈平安抬头看了一眼天色，背起竹篓往山上走，山风穿过松林，带着一股凉意。',
    '少年停在半山腰，听见溪水在石头底下响，像是在说话，又像是什么都没说。',
    '他从怀里摸出一枚旧铜钱，指腹在边缘磨了磨，铜钱滚烫，像是刚从火里捞出来。',
    '远处传来钟声，一声接一声，惊起满林飞鸟，也惊醒了睡在云里的那座小镇。',
  ].join();

  @override
  Future<BackendResponse> send(
    String method,
    String path, {
    String? query,
    Uint8List? body,
    Duration timeout = BackendTransport.defaultTimeout,
  }) async => BackendResponse(
    200,
    Uint8List.fromList(utf8.encode(jsonEncode(_payloadFor(path)))),
    'application/json',
  );

  Map<String, dynamic> _payloadFor(String path) {
    if (path.endsWith('/directory')) {
      return {
        'code': 0,
        'data': {
          'item_data_list': [
            for (var i = 1; i <= chapterCount; i++)
              {
                'item_id': 'perf-$runId-c$i',
                'title': '第$i章 性能样本',
                'volume_name': '第一卷',
              },
          ],
        },
      };
    }
    if (path.contains('/chapters/')) {
      return {
        'code': 0,
        'data': {
          'content_decrypted': true,
          'title': '性能样本',
          'content': [
            for (var p = 0; p < paragraphCount; p++) '<p>$_paragraph</p>',
          ].join(),
        },
      };
    }
    if (path.endsWith('/detail')) {
      return {
        'code': 0,
        'data': {
          'book_id': 'perf-$runId',
          'book_name': '性能样本',
          'author_info': {'name': 'perf'},
          'thumb_url': '',
        },
      };
    }
    return {'code': 0, 'data': {}};
  }
}
