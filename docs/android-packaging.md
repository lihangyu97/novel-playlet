# Android 打包（第一个 APK）

本仓库原本只支持 iOS。这份文档记录把 Android 打包链路补齐所必需的改动、构建步骤和边界。

**边界**：只做打包——Android 工程、Manifest / 网络 / 备份、图标、签名、Rust 内核的 `.so` 交叉编译。
不改 `lib/` 里的业务逻辑；视频、缓存等运行时行为等业务改造完再按真机验证结果处理。

## 一、工具链

本机已验证的版本（与 iOS 侧一致的那几个版本不要漂）：

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.9 | 决定 `compileSdk=36`、`minSdk=24`、`ndkVersion=28.2.13676358` |
| Rust | 1.99.1 | `rustup target add aarch64-linux-android`（需要 32 位再加 `armv7-linux-androideabi`） |
| flutter_rust_bridge | 2.13.0 | codegen 与 `rust/Cargo.toml` 必须同版本 |
| JDK | 17 | Homebrew `openjdk@17`（keg-only） |
| Android SDK | 36 + Build-Tools 36.0.0 + platform-tools | `sdkmanager` 安装 |
| Android NDK | 28.2.13676358 | 与 Flutter 默认 `ndkVersion` 一致，脚本会校验 |

本机路径（换机器时改环境变量即可）：

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$ANDROID_HOME/platform-tools:$PATH"
```

## 二、仓库里的改动

- `android/`：`flutter create --platforms=android --org com.lihangyu` 生成后做了这些调整：
  - `app/src/main/AndroidManifest.xml`：补 `INTERNET` 权限（release 必需）、`android:networkSecurityConfig`、
    `allowBackup=false` + 备份排除规则、显示名「摆烂盒子」。
  - `app/src/main/res/xml/network_security_config.xml`：只放行 `127.0.0.1` / `localhost` 的明文回环，
    对应 iOS `Info.plist` 里的 ATS 例外（视频走内核 `http://127.0.0.1:18931/src/*`）。
  - `app/src/main/res/xml/backup_rules.xml` + `data_extraction_rules.xml`：设备池和阅读数据不出设备。
  - `app/src/main/res/mipmap-*/ic_launcher.png`：从 iOS 的 1024 图标缩放生成。
  - `app/build.gradle.kts`：从 `android/key.properties` 读取正式签名；没有配置时回退 debug 签名。
  - `app/src/main/jniLibs/**/*.so`：Rust 内核产物，由脚本重建，`.gitignore` 已排除。
- `scripts/build_rust_android.sh`：FRB codegen + NDK 交叉编译 + 放进 jniLibs + 校验 FRB 导出符号和 16 KiB 对齐。
- `.metadata`：补上 android 平台；`analysis_options.yaml` 排除 `android/**`。

Android 侧加载 Rust 内核不需要改 Dart：iOS 是静态库 + `ExternalLibrary.process()`，
Android 是 `.so` + flutter_rust_bridge 默认的 `DynamicLibrary.open('libfqapi_core.so')`
（见 `lib/core/backend/rust_bootstrap_io.dart`）。

## 三、构建

```bash
# 1) 编内核共享库（默认只 arm64-v8a）
./scripts/build_rust_android.sh
# 需要 32 位设备时：
./scripts/build_rust_android.sh --abis all

# 2) 出 release APK
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

双 ABI 拆分包（两个 APK）：

```bash
./scripts/build_rust_android.sh --abis all
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
# 产物：app-arm64-v8a-release.apk / app-armeabi-v7a-release.apk
```

安装：`adb install -r build/app/outputs/flutter-apk/app-release.apk`（手机需开 USB 调试）。

## 四、签名

正式签名材料放在仓库外，本地用 `android/key.properties` 指向（该文件被 git 忽略）：

```properties
storeFile=/Users/lihangyu/keys/novel-playlet-release.jks
storePassword=***
keyAlias=novelplaylet
keyPassword=***
```

- 换机器/交接时必须把 `~/keys/novel-playlet-release.jks` 和这份 password 一起带走，否则无法覆盖升级。
- 没有 `android/key.properties` 时，release 会退回 debug 签名，只能本机自测，**不能升级成正式签名包**。
- applicationId `com.lihangyu.novel_playlet` 第一次发出去后不要再改。

## 五、运行时行为：哪些已处理、哪些等业务改造

打包层已经处理（不做这些，APK 会“能装但不可用”）：

- release 包的 `INTERNET` 权限；
- 本地回环明文 HTTP（视频 `/src`）；
- 备份/迁移排除（避免恢复后设备池与 Keystore 密钥对不上）；
- 图标、显示名、版本号（`pubspec.yaml` 的 `0.6.0+14`）。

留给业务改造后再处理（本次刻意不改）：

- 视频播放：Android 走 ExoPlayer；loopback `/src` 的兼容性、全屏/横竖屏切换、退后台行为需要真机验证。
- 缓存路径：当前代码全部走 `path_provider` 的 `getApplicationSupportDirectory()` /
  `getTemporaryDirectory()`，Android 对应 App 私有目录，**无需平台分支**；只有真机上的占用统计
  和清理体验需要复验。
- 设备池密钥：`flutter_secure_storage` 在 Android 上走 Keystore，现有失败降级逻辑已存在，真机复验即可。
- 错误文案：`lib/features/video/video_player_page.dart` 里有 iOS ATS 专用的提示，Android 上需要改成
  平台无关文案（属于业务改动，本次未动）。

## 六、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 启动即停在「阅读环境启动失败」，logcat 有 `UnsatisfiedLinkError` | `.so` 没编或 ABI 不匹配：先跑 `scripts/build_rust_android.sh`，确认 APK 里有 `lib/arm64-v8a/libfqapi_core.so` |
| release 包能启动但一直失败 | 主清单缺 `INTERNET`（本仓库已补）；用 `adb shell dumpsys package com.lihangyu.novel_playlet \| grep INTERNET` 确认 |
| 播放短剧报 `PanicException(Expect rustls-platform-verifier to be initialized)` | 旧包的视频流式下载用了 reqwest 默认 TLS（Android 上需要 JNI 初始化）；已改为复用 webpki-roots 配置，重新构建安装即可 |
| 视频黑屏 / 播放报错 | `network_security_config` 没生效，检查 `127.0.0.1` 域名配置和端口 |
| 装不上、提示签名不一致 | 新旧包签名不同（debug vs release），先卸载再装 |
| 小米/HyperOS 上 `adb install` 报 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user` | 系统拦截了 adb 安装：开发者选项里打开「USB 安装」（可能需要登录小米账号），并在手机弹窗里点允许；临时办法是把 APK 放到 `/sdcard/Download/` 用文件管理手动安装 |
| Gradle 报找不到 NDK | `sdkmanager "ndk;28.2.13676358"`，并确认 `ndkVersion` 与脚本 pinned 版本一致 |
| 想上架 Google Play | 还需 targetSdk 合规、16 KiB 对齐、隐私政策；GPL-3.0 与内容授权问题见 README“已知限制” |
