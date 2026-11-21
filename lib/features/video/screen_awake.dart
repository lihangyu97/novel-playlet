import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 播放页保持屏幕常亮的平台通道。
///
/// 原生侧只负责把系统空闲计时器关掉/恢复：
/// - iOS：`UIApplication.shared.isIdleTimerDisabled`
/// - Android：`WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`
///
/// 这是增强能力：通道未注册（桌面/测试）或原生调用失败时静默忽略，
/// 不能因为“没保持常亮”把播放页弄挂。
abstract interface class ScreenAwakeController {
  Future<void> setKeepAwake(bool enabled);
}

class PlatformScreenAwakeController implements ScreenAwakeController {
  const PlatformScreenAwakeController();

  static const channelName = 'novel_playlet/screen_awake';
  static const _channel = MethodChannel(channelName);

  @override
  Future<void> setKeepAwake(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('set', enabled);
    } catch (_) {
      // 保持常亮失败不影响播放；系统会按 Auto-Lock 正常熄屏。
    }
  }
}

final screenAwakeControllerProvider = Provider<ScreenAwakeController>(
  (ref) => const PlatformScreenAwakeController(),
);
