import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 设置页版本脚注用的方法通道。引擎由 storyboard 隐式创建，通道挂在
  /// `applicationRegistrar` 的 messenger 上（见 `FlutterImplicitEngineBridge`）。
  /// 通道名/方法名要与 `lib/app/app_version.dart`、
  /// `android/.../MainActivity.kt` 一致。
  private var appVersionChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerAppVersionChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }

  private func registerAppVersionChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "novel_playlet/app_version",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "get" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // 就是从安装包 Info.plist 读，版本号在打包时由 pubspec 的
      // `version: x.y.z+n` 写入，release/beta 各自显示自己的值。
      let info = Bundle.main.infoDictionary
      result([
        "versionName": info?["CFBundleShortVersionString"] as? String ?? "",
        "buildNumber": info?["CFBundleVersion"] as? String ?? "",
      ])
    }
    appVersionChannel = channel
  }
}
