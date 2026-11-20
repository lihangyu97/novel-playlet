package com.lihangyu.novel_playlet

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 设置页版本脚注：与 ios/Runner/AppDelegate.swift 的通道名/方法名对齐。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "novel_playlet/app_version")
            .setMethodCallHandler { call, result ->
                if (call.method != "get") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val info = packageManager.getPackageInfo(packageName, 0)
                val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.longVersionCode.toString()
                } else {
                    info.versionCode.toString()
                }
                result.success(
                    mapOf(
                        "versionName" to (info.versionName ?: ""),
                        "buildNumber" to build,
                    ),
                )
            }
        registerSystemStatusChannel(flutterEngine)
    }

    // 播放页横屏全屏右上角的状态通道。字段与
    // `lib/features/video/player_system_status.dart`、`ios/Runner/AppDelegate.swift` 对齐。
    private fun registerSystemStatusChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "novel_playlet/system_status")
            .setMethodCallHandler { call, result ->
                if (call.method != "read") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(readSystemStatus())
            }
    }

    private fun readSystemStatus(): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>()

        val battery = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val percent = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        if (percent in 0..100) payload["batteryPercent"] = percent

        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val caps = manager?.let { cm ->
            cm.activeNetwork?.let { network -> cm.getNetworkCapabilities(network) }
        }
        when {
            caps == null -> payload["networkType"] = "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ->
                payload["networkType"] = "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                payload["networkType"] = "cellular"
                cellularLabel()?.let { payload["radio"] = it }
            }
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
                payload["networkType"] = "wired"
            else -> payload["networkType"] = "unknown"
        }
        return payload
    }

    // Android 12+ 读 dataNetworkType 需要 READ_PHONE_STATE；没授权就返回
    // null，Dart 侧显示「蜂窝」，不影响其它项。
    private fun cellularLabel(): String? {
        val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return null
        val type = try {
            telephony.dataNetworkType
        } catch (_: SecurityException) {
            return null
        }
        return when (type) {
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            TelephonyManager.NETWORK_TYPE_LTE -> "4G"
            TelephonyManager.NETWORK_TYPE_UMTS,
            TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_HSPA,
            TelephonyManager.NETWORK_TYPE_HSPAP,
            TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A,
            TelephonyManager.NETWORK_TYPE_EVDO_B,
            TelephonyManager.NETWORK_TYPE_EHRPD -> "3G"
            TelephonyManager.NETWORK_TYPE_GPRS,
            TelephonyManager.NETWORK_TYPE_EDGE,
            TelephonyManager.NETWORK_TYPE_GSM,
            TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT,
            TelephonyManager.NETWORK_TYPE_IDEN -> "2G"
            else -> null
        }
    }
}
