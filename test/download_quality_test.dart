import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_playlet/features/cache/download_quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// S3：离线下载清晰度偏好（默认 720P，落盘、冷启动恢复）。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认 720P', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p720,
    );
    expect(VideoDownloadQuality.p720.maxHeight, 720);
  });

  test('改清晰度落盘，新容器能恢复', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(videoDownloadQualityProvider.notifier)
        .setQuality(VideoDownloadQuality.p1080);
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(VideoDownloadQualityController.prefsKey), 1080);

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(
      restored.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p720,
    );
    await pumpEventQueue();
    expect(
      restored.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p1080,
    );
  });

  test('落盘值不认识时回退到不设上限/未知档显示', () async {
    SharedPreferences.setMockInitialValues({
      VideoDownloadQualityController.prefsKey: 9999,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 先读一次触发 build（首帧默认值），再给异步补读留一拍。
    expect(
      container.read(videoDownloadQualityProvider),
      VideoDownloadQuality.p720,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container.read(videoDownloadQualityProvider),
      VideoDownloadQuality.best,
    );
  });
}
