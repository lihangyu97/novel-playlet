package com.lihangyu.novel_playlet

import android.os.Build
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
    }
}
