import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/backend/backend_service.dart';
import '../core/storage/reading_store.dart';
import '../data/api/api_client.dart';

/// 进程级内核服务。启动在 [bootstrapProvider] 里完成，页面只依赖它的 transport。
final backendServiceProvider = Provider<BackendService>(
  (ref) => BackendService.instance,
);

/// 业务接口。页面/controller 通过它拿数据，不直接碰 transport。
final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(ref.watch(backendServiceProvider).transport),
);

/// 回环自愈入口：探活失败时重启内核（同端口重绑），见
/// [BackendService.ensureLoopback]。
///
/// 抽成 Provider 是为了播放页的 -1004 一次性恢复在 widget 测试里能替换成
/// fake，不真的在测试进程里重启内核。
final backendEnsureLoopbackProvider = Provider<Future<bool> Function()>(
  (ref) => ref.watch(backendServiceProvider).ensureLoopback,
);

/// 书架与阅读进度。
final readingStoreProvider = Provider<ReadingStore>((ref) => ReadingStore());

/// 启动闸门：部署运行时文件并启动 Rust 核。
///
/// 失败时把异常原样抛给 [BootstrapGate]，由它展示原因和重试按钮——内核起
/// 不来时任何页面都没有意义，所以在进首页之前就要完成。
final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(backendServiceProvider).start();
});
