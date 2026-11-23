import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名材料放在仓库外：本地用 android/key.properties（被 git 忽略）指向 ~/keys 下的 jks。
// 缺失时回退 debug 签名，保证没有私钥的人也能构建一个能安装的包，但不会把 release 包
// 伪装成正式签名——要发版就先把 key.properties 配好。
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(key: String): String? =
    keystoreProperties.getProperty(key)?.takeIf { it.isNotBlank() }

val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { signingValue(it) != null }

// Flutter 只编一个 ABI 时，插件 AAR 里其它 ABI 的 .so 仍会被合并进来，APK 的
// native-code 就会误报成多 ABI（32 位设备装上后缺 Flutter 引擎而闪退）。
// 按本次构建的 target-platform 把没有引擎的 ABI 从打包里排除。
val allAndroidAbis = setOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
val requestedAndroidAbis: Set<String> = (project.findProperty("target-platform") as String?)
    ?.split(",")
    ?.mapNotNull {
        when (it.trim()) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x64" -> "x86_64"
            "android-x86" -> "x86"
            else -> null
        }
    }
    ?.toSet()
    .orEmpty()

android {
    namespace = "com.lihangyu.novel_playlet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用 ID 一旦发出去就不能改（改了就变成另一个 App，无法覆盖升级）。
        applicationId = "com.lihangyu.novel_playlet"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(signingValue("storeFile")!!)
                storePassword = signingValue("storePassword")
                keyAlias = signingValue("keyAlias")
                keyPassword = signingValue("keyPassword")
                // minSdk 24 的机器都支持 V2；保留 V1 兼容部分旧 OEM 安装器。
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // 没有 android/key.properties 时用 debug key 签名，仅够本机自测；
                // 这种包以后不能覆盖升级成正式签名版本。
                signingConfigs.getByName("debug")
            }
        }
    }

    // release / beta 两个渠道包（打 APK 走 scripts/build_android_app.sh）。
    //
    // 渠道名不用 release/debug：和 build type 同名时 variant / task 命名容易歧义
    // （assembleReleaseRelease 之类），所以正式渠道叫 prod，脚本对外仍是 --flavor release。
    // 加了 flavor 之后所有 APK 构建都要带 `--flavor prod|beta`，否则 Flutter 找不到
    // app-<flavor>-<type>.apk。
    //
    // beta 用独立 applicationId（.beta 后缀）配独立显示名：两个包可以和 iOS
    // 一样同时装在一台机器上，数据容器互不覆盖；端口由构建脚本用
    // --dart-define=BACKEND_PORT=18932 覆盖（见 docs/implementation.md §7.2）。
    flavorDimensions += "channel"
    productFlavors {
        create("prod") {
            dimension = "channel"
        }
        create("beta") {
            dimension = "channel"
            applicationIdSuffix = ".beta"
        }
    }

    packaging {
        jniLibs {
            if (requestedAndroidAbis.isNotEmpty()) {
                excludes += (allAndroidAbis - requestedAndroidAbis).map { "lib/$it/**" }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
