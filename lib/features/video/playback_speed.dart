import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放页可选的倍速（按展示顺序）。
///
/// 不加 0.75x：短剧慢放需求低，且 <1x 会多一条 AVPlayer 的
/// `canPlaySlowForward` 能力校验，先不引入额外变量。
const playbackSpeeds = <double>[1.0, 1.25, 1.5, 2.0, 3.0];

/// 倍速偏好：全局单值、跨集/退出播放页/冷启动都保持。
///
/// 播放页只把 provider 当唯一真相：改速时写这里，页面监听后下发到当前
/// controller；新建 controller（切集/换源）时在 `_startController` 里重新
/// apply——`video_player` 的新 controller 默认回到 1.0x，不会继承旧的。
final playbackSpeedProvider = NotifierProvider<PlaybackSpeedController, double>(
  PlaybackSpeedController.new,
);

class PlaybackSpeedController extends Notifier<double> {
  static const prefsKey = 'video_playback_speed_v1';

  /// 磁盘读取返回前用户就改过倍速时，不能被旧的落盘值覆盖。
  bool _userChanged = false;

  @override
  double build() {
    _restore();
    return 1.0;
  }

  void setSpeed(double value) {
    // 只接受白名单，避免脏值被写进偏好、下次启动播不出正常速度。
    if (!playbackSpeeds.contains(value) || value == state) return;
    _userChanged = true;
    state = value;
    _persist(value);
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _userChanged) return;
      final stored = prefs.getDouble(prefsKey);
      if (stored != null &&
          playbackSpeeds.contains(stored) &&
          stored != state) {
        state = stored;
      }
    } catch (_) {
      // 读不到偏好就用默认 1.0x，不影响播放。
    }
  }

  Future<void> _persist(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await prefs.setDouble(prefsKey, value);
    } catch (_) {
      // 落盘失败只影响下次启动的默认值，当前这次改速仍然生效。
    }
  }
}

/// chip/弹层展示用的倍速文案：`1.0x` / `1.25x` / `2.0x`。
String playbackSpeedLabel(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toStringAsFixed(1)
      : speed.toString();
  return '${text}x';
}
