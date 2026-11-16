import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_status.dart';

/// 在 App 回到前台、退到后台时各尝试同步一次。
///
/// 阅读进度是防抖落盘的，云同步不能在每次落盘时触发；生命周期节点 + 设置页
/// 手动按钮已经覆盖个人使用场景，也不会浪费 WebDAV 流量。
///
/// 阅读页在 `inactive` 就把当前页落盘，比这里的 `paused` 更早，所以后台这
/// 一次同步读到的是最新进度，不会上传防抖窗口里的旧落点。
class SyncLifecycle extends ConsumerStatefulWidget {
  const SyncLifecycle({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncLifecycle> createState() => _SyncLifecycleState();
}

class _SyncLifecycleState extends ConsumerState<SyncLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      _sync();
    }
  }

  void _sync() {
    // 自动同步不抛错：网络/配置问题由设置页卡片展示，不能打断启动。
    unawaited(ref.read(syncStatusProvider.notifier).syncNow());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
