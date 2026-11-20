import CoreTelephony
import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 设置页版本脚注用的方法通道。引擎由 storyboard 隐式创建，通道挂在
  /// `applicationRegistrar` 的 messenger 上（见 `FlutterImplicitEngineBridge`）。
  /// 通道名/方法名要与 `lib/app/app_version.dart`、
  /// `android/.../MainActivity.kt` 一致。
  private var appVersionChannel: FlutterMethodChannel?

  /// 播放页横屏全屏右上角的状态通道：电量 + 当前网络类型（WiFi / 蜂窝 4G/5G）。
  /// 通道名/字段与 `lib/features/video/player_system_status.dart`、
  /// `android/.../MainActivity.kt` 保持一致。
  private var systemStatusChannel: FlutterMethodChannel?

  /// 网络路径（WiFi / 蜂窝）用它判断；后台常驻一个 monitor 即可。
  private let pathMonitor = NWPathMonitor()
  private let pathMonitorQueue = DispatchQueue(
    label: "com.lihangyu.novelPlaylet.networkPath"
  )

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 电量监控默认关闭，打开后才能读到 batteryLevel。
    UIDevice.current.isBatteryMonitoringEnabled = true
    pathMonitor.start(queue: pathMonitorQueue)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerAppVersionChannel(messenger: messenger)
    registerSystemStatusChannel(messenger: messenger)
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

  private func registerSystemStatusChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "novel_playlet/system_status",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.systemStatusPayload() ?? ["networkType": "unknown"])
    }
    systemStatusChannel = channel
  }

  /// 读一次电量/网络。任何一项拿不到就不放这个 key，Dart 侧对应项不展示。
  private func systemStatusPayload() -> [String: Any] {
    var payload: [String: Any] = [:]

    let level = UIDevice.current.batteryLevel
    if level >= 0 {
      payload["batteryPercent"] = Int((level * 100).rounded())
    }

    let path = pathMonitor.currentPath
    guard path.status == .satisfied else {
      payload["networkType"] = "none"
      return payload
    }
    if path.usesInterfaceType(.wifi) {
      payload["networkType"] = "wifi"
    } else if path.usesInterfaceType(.cellular) {
      payload["networkType"] = "cellular"
      if let radio = currentCellularLabel() {
        payload["radio"] = radio
      }
    } else if path.usesInterfaceType(.wiredEthernet) {
      payload["networkType"] = "wired"
    } else {
      payload["networkType"] = "unknown"
    }
    return payload
  }

  /// 4G/5G 只能靠 CoreTelephony：NWPathMonitor 只到 cellular 这一层。
  /// 双卡取当前数据卡；没有服务时返回 nil，Dart 侧显示「蜂窝」。
  private func currentCellularLabel() -> String? {
    // serviceCurrentRadioAccessTechnology 在 iOS 16 起标记弃用，但仍是公开
    // API 里唯一能拿到当前无线制式（LTE / NR）的入口。
    let info = CTTelephonyNetworkInfo()
    guard let tech = info.serviceCurrentRadioAccessTechnology?.values.first else {
      return nil
    }
    switch tech {
    case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
      return "5G"
    case CTRadioAccessTechnologyLTE:
      return "4G"
    case CTRadioAccessTechnologyWCDMA,
      CTRadioAccessTechnologyHSDPA,
      CTRadioAccessTechnologyHSUPA,
      CTRadioAccessTechnologyCDMAEVDORev0,
      CTRadioAccessTechnologyCDMAEVDORevA,
      CTRadioAccessTechnologyCDMAEVDORevB,
      CTRadioAccessTechnologyCDMA1x:
      return "3G"
    case CTRadioAccessTechnologyEdge,
      CTRadioAccessTechnologyGPRS:
      return "2G"
    default:
      return nil
    }
  }
}
