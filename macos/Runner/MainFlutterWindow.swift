import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 设置页版本脚注用的方法通道。通道名/方法名要与 `lib/app/app_version.dart`、
  /// iOS `AppDelegate.swift`、Android `MainActivity.kt` 一致。
  private var appVersionChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 桌面窗口的可用尺寸：再窄推荐页双列卡片与阅读器分页都会挤坏（见 docs/implementation.md
    // 的 macOS 一节）。默认给一个笔记本上舒服的宽度，用户拖动后不再强制复位。
    self.minSize = NSSize(width: 900, height: 700)
    if windowFrame.width < 1000 || windowFrame.height < 760 {
      self.setContentSize(NSSize(width: 1200, height: 860))
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerAppVersionChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
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
      // `version: x.y.z+n` 写入。
      let info = Bundle.main.infoDictionary
      result([
        "versionName": info?["CFBundleShortVersionString"] as? String ?? "",
        "buildNumber": info?["CFBundleVersion"] as? String ?? "",
      ])
    }
    appVersionChannel = channel
  }
}
