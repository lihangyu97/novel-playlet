import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/backend/backend_service.dart';
import '../core/diagnostics/diagnostic_log.dart';
import '../core/storage/library_records.dart';
import '../core/storage/reading_store.dart';
import '../data/api/api_client.dart';

/// 进程级内核服务。启动在 [bootstrapProvider] 里完成，页面只依赖它的 transport。
final backendServiceProvider = Provider<BackendService>(
  (ref) => BackendService.instance,
);

/// 业务接口。页面/controller 通过它拿数据，不直接碰 transport。
final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(
    ref.watch(backendServiceProvider).transport,
    logStore: ref.watch(diagnosticLogStoreProvider),
  ),
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

/// 「在看」变更计数：阅读页 / 播放页的悬浮按钮与「我的」页共用。
final pinRevisionProvider = NotifierProvider<PinRevision, int>(PinRevision.new);

class PinRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(readingStoreProvider);
    void onChanged() => state = store.pinRevision.value;
    store.pinRevision.addListener(onChanged);
    ref.onDispose(() => store.pinRevision.removeListener(onChanged));
    return store.pinRevision.value;
  }
}

/// 某条内容当前是否在「在看」里。
///
/// 阅读页 / 播放页的悬浮按钮订阅它；切换 pin 后 [pinRevisionProvider] 变化，
/// 按钮图标自动跟着切换。
final libraryPinnedProvider = FutureProvider.autoDispose
    .family<bool, ({LibraryType type, String id})>((ref, key) async {
      ref.watch(pinRevisionProvider);
      return ref.watch(readingStoreProvider).isPinned(key.type, key.id);
    });

/// 启动闸门：部署运行时文件并启动 Rust 核。
///
/// 失败时把异常原样抛给 [BootstrapGate]，由它展示原因和重试按钮——内核起
/// 不来时任何页面都没有意义，所以在进首页之前就要完成。
final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(backendServiceProvider).start();
  // 首次安装时，系统联网权限弹窗（国产 ROM 的「允许使用 WLAN 和移动数据」、
  // iOS 的无线数据提示）要等 App 第一次真实联网才出现，而弹窗期间请求会被
  // 系统直接拒掉。这里顺手发一次最小请求，把弹窗提前到启动页
  // （[BootstrapGate] 的「正在准备阅读环境…」），不要在首页骨架后面才弹。
  //
  // 不 await：弹窗挂着时这次请求可能很久才失败，不能拖住进首页；失败也不
  // 需要处理，首屏自己的有限重试会兜住（见 RecommendFeedController）。
  unawaited(ref.read(apiClientProvider).warmUpNetwork());
});
