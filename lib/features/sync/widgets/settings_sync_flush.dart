import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings_sync_coordinator.dart';

/// 离开设置页时立刻 flush 设置同步的去抖队列。
///
/// 只影响推送，不做拉取：此时页面已经要退出，回填设置没有意义。
class SettingsSyncFlush extends ConsumerStatefulWidget {
  const SettingsSyncFlush({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SettingsSyncFlush> createState() => _SettingsSyncFlushState();
}

class _SettingsSyncFlushState extends ConsumerState<SettingsSyncFlush> {
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    final container = _container;
    if (container == null) {
      super.dispose();
      return;
    }
    // dispose 是 widget 生命周期，flush 可能改 provider 状态，延后一拍。
    unawaited(
      Future<void>.microtask(() async {
        try {
          await container.read(settingsSyncStatusProvider.notifier).flush();
        } catch (_) {
          // 页面销毁时容器已收尾：这次 flush 放弃即可，下次启动会补推。
        }
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
