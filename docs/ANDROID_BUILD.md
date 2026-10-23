# Android 构建指南（Godot 4.7.2）

本文说明如何从零克隆本仓库并构建出可安装的 Android APK。  
适合第一次接触本工程的人，也适合换机器/重装系统后照着做。

> **结论先说**：本仓库的 `android/` 目录是**生成目录**，不在 git 里（见 `.gitignore` 的 `/android/`）。  
> 克隆后没有它，第一次构建需要先安装 Godot 的 Android 构建模板，然后再导出。  
> 本工程没有手工修改 Gradle / AndroidManifest，模板与官方 Godot 4.7.2 **完全一致**，所以按本文步骤可以稳定复现。

---

## 0. 快速开始（TL;DR）

```bash
git clone git@github.com:CantanTam/blecaco_phone.git
cd blecaco_phone

# 依赖（见第 1 节）：Godot 4.7.2 + 导出模板
#                   Android SDK 36 / Build-Tools 36.1.0 / NDK 29.0.14206865
#                   JDK 17
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"   # 按你的 JDK 17 路径改
export PATH="$ANDROID_HOME/platform-tools:$PATH"

# 首次：安装 Android 构建模板 + 直接导出 debug APK
godot --headless --install-android-build-template --export-debug "Android" /tmp/Blecaco-debug.apk

# 安装到手机
adb install -r /tmp/Blecaco-debug.apk
adb shell am force-stop com.blecaco.mobile
```

第一次 Gradle 构建会下载 AGP / Kotlin / AndroidX 依赖，通常要几分钟，请保持网络畅通。

---

## 1. 环境准备

### 1.1 Godot

- 版本：**Godot 4.7.2 stable（标准版，不是 .NET 版）**
- 必须安装对应的 **Export Templates 4.7.2**：
  - 编辑器菜单：`Editor → Manage Export Templates... → Download and Install`
  - 或手动把 `Godot_v4.7.2-stable_export_templates.tpz` 放到
    `~/.local/share/godot/export_templates/4.7.2.stable/`
- 验证：

```bash
godot --version
# 期望：4.7.2.stable.official.<hash>
```

> 不要用 4.6/4.8 混搭：`android/build` 模板、`godot-lib` AAR、生成的 manifest 都绑定 4.7.2。  
> 换 Godot 版本时，重新安装 Android 构建模板（见第 3 节）。

### 1.2 JDK 17

工程的 Gradle 配置要求 **Java 17**（`config.gradle` 里 `JavaVersion.VERSION_17`）。

```bash
# Ubuntu / Debian 示例
sudo apt install openjdk-17-jdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
```

验证：

```bash
java -version   # 期望 17.x
```

> 用 JDK 21 跑 Gradle 可能报 `Unsupported class file major version`；请显式用 17。  
> 也可以在 Godot 的 `Editor Settings → Export → Android → Java SDK Path` 里指定 JDK 17。

### 1.3 Android SDK / NDK

推荐直接用 Android Studio 的 SDK Manager，或用 command-line tools。需要安装：

| 组件 | 版本 | 说明 |
|---|---|---|
| SDK Platform | **Android 16 (API 36)** | `platforms;android-36` |
| Build-Tools | **36.1.0** | `build-tools;36.1.0` |
| NDK | **29.0.14206865** | `ndk;29.0.14206865` |
| Platform-Tools | 最新 | 提供 `adb` |
| CMake | 3.22.1（可选） | 本工程用预编译 AAR，不重新编译原生代码；只有改原生插件/引擎时才需要 |

用 `sdkmanager` 安装（路径按你的 SDK 调整）：

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

yes | sdkmanager --licenses
sdkmanager \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.1.0" \
  "ndk;29.0.14206865"
```

验证：

```bash
adb version
ls "$ANDROID_HOME/platforms"      # 应看到 android-36
ls "$ANDROID_HOME/build-tools"    # 应看到 36.1.0
ls "$ANDROID_HOME/ndk"            # 应看到 29.0.14206865
```

> 如果使用 Android Studio：`Settings → Languages & Frameworks → Android SDK`，  
> 在 **SDK Platforms** 勾选 Android 16 (API 36)，在 **SDK Tools** 勾选 Build-Tools 36.1.0、NDK 29.0.14206865、Platform-Tools。

### 1.4 Godot 的 Android 导出设置

打开 Godot：`Editor → Editor Settings → Export → Android`，设置：

- **Android SDK Path**：你的 SDK 目录，例如 `/home/you/Android/Sdk`
- **Debug Keystore**：`~/.config/godot/debug.keystore`（首次导出时 Godot 会生成；也可以用已有的 debug keystore）
- **Debug Keystore User**：`androiddebugkey`
- **Debug Keystore Pass**：`android`

这些是**本机设置**，不会进仓库。  
Debug APK 用这个 keystore 签名；Release 签名见第 4.2 节。

---

## 2. 克隆并首次打开工程

```bash
git clone git@github.com:CantanTam/blecaco_phone.git
cd blecaco_phone

# 第一次用编辑器打开，让 Godot 导入资源、加载插件
godot --editor --path .
```

首次打开会：

- 生成 `.godot/` 导入缓存（已被 git 忽略）
- 加载 `project.godot` 里启用的 editor plugins：
  - `GodotAndroidPluginTemplate`
  - `NativeCameraPlugin`
  - `gdscript_digit_mapper`
  - `OpenVINSGodot`

> 这些插件里，`NativeCameraPlugin` 和 `OpenVINSGodot` 会通过 `_get_android_libraries()`  
> 把 `addons/*/bin/<debug|release>/*.aar` 挂进 Android 导出。  
> **不要禁用它们**，否则 APK 会缺少相机/VIO 原生库。  
> `android/` 目录这时还不存在，属于正常现象。

---

## 3. 安装 Android 构建模板（首次必须）

本工程使用 Gradle 构建（`export_presets.cfg` 里 `gradle_build/use_gradle_build=true`），  
所以需要 `android/build` 模板。它**没有**提交到 git，因为：

- 是由 Godot 的 `android_source.zip` 生成的
- 完整目录约 **1.1GB**（包含 Gradle 缓存和构建输出）
- 本工程没有手工改动，官方 4.7.2 模板即可复现

### 方式 A：CLI（推荐，克隆后一条命令）

```bash
godot --headless --install-android-build-template \
  --export-debug "Android" /tmp/Blecaco-debug.apk
```

这条命令会先安装模板到 `android/build`，再导出 debug APK。  
**模板已存在时不要加 `--install-android-build-template`**，直接 `--export-debug` 即可。

### 方式 B：编辑器 GUI

1. 打开工程
2. 菜单 `Project → Install Android Build Template...`
3. 确认安装（会创建 `android/build`）
4. 之后用 `Project → Export... → Android → Export Project`，或 CLI 导出

### 注意

- 如果 `android/` 已存在但版本不对/损坏：
  ```bash
  rm -rf android
  godot --headless --install-android-build-template --export-debug "Android" /tmp/Blecaco-debug.apk
  ```
  （`android/` 是生成目录且被 git 忽略；本工程没有需要保留的手改。）
- **不要把 `android/` 提交到 git**，也不要手动改里面的 manifest/资源；导出过程会重新生成 `src/debug`、`src/release`。

---

## 4. 导出 APK

### 4.1 Debug（日常测试用）

```bash
cd blecaco_phone
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

godot --headless --export-debug "Android" /tmp/Blecaco-debug.apk
```

- Preset 名称必须是 **`Android`**（`export_presets.cfg` 里的名字）。
- 输出路径可以任意；示例用 `/tmp`，不会污染仓库。
- 产物：**arm64-v8a**，minSdk 24，targetSdk 36。
- 签名：使用 Godot 的 debug keystore，可以直接安装。

### 4.2 Release（可选，需要签名）

Release 需要自己的 keystore。先生成（只做一次，**不要把 keystore 提交到 git**）：

```bash
keytool -genkeypair -v \
  -keystore "$HOME/blecaco-release.keystore" \
  -alias blecaco \
  -keyalg RSA -keysize 2048 -validity 10000
```

然后在 Godot 里：

1. `Project → Export...` → 选中 `Android`
2. 找到 **Keystore** 区域：
   - **Release Keystore**：`/home/you/blecaco-release.keystore`
   - **Release User**：`blecaco`
   - **Release Password**：你设置的密码
3. 保存预设后导出：

```bash
godot --headless --export-release "Android" /tmp/Blecaco-release.apk
```

> ⚠️ `export_presets.cfg` 是**已跟踪文件**。在编辑器里填 release keystore 密码后，密码会被写进这个文件。  
> **不要把带密码的 `export_presets.cfg` 提交**；建议本地填完就清空，或在 CI 里用 secret 注入。  
> 本仓库当前的 `export_presets.cfg` 没有 release keystore 配置。

- 导出格式默认 **APK**（`gradle_build/export_format=0`）。  
  如果要 **AAB**，在导出对话框里选 Android App Bundle，或把该值改为 `1`。
- Release 的 `version/code` / `version/name` 在 `export_presets.cfg` 里改；当前是 code=1、name 默认 1.0。

---

## 5. 安装、启动、看日志

```bash
# 确认设备
adb devices

# 安装（-r 覆盖安装）
adb install -r /tmp/Blecaco-debug.apk

# 必须 force-stop，避免旧进程继续跑
adb shell am force-stop com.blecaco.mobile

# 启动（也可以直接在手机上点图标）
adb shell monkey -p com.blecaco.mobile -c android.intent.category.LAUNCHER 1

# 看 Godot 日志
adb logcat -s godot:V
```

**包名**：`com.blecaco.mobile`（来自 `export_presets.cfg` 的 `package/unique_name`，已通过 APK 合并 manifest 确认）。

> 旧版 `HANDOFF.md` 里的 `adb shell am force-stop com.example.blecaco` 是**旧包名**，不要再用。  
> 可以用 `adb shell pm list packages | grep blecaco` 确认当前安装包。

如果覆盖安装报签名冲突：

```bash
adb uninstall com.blecaco.mobile
adb install /tmp/Blecaco-debug.apk
```

---

## 6. 首次运行（连 Blender）

APK 装好后，App 需要连接 Blender 的 Blecaco 插件：

1. 电脑和手机连**同一个局域网**
2. 在 Blender 里启用 Blecaco 插件并启动 WebSocket 服务（默认端口 **12121**）
3. 手机打开 App，扫描插件面板的二维码（或手动填写电脑的局域网 IP / 端口）
4. 首次使用相机模式时，允许 **相机权限**

排查连接问题：

- 电脑防火墙放行 TCP **12121**
- 电脑上确认端口在监听：`ss -ltnp | grep 12121`（或 `lsof -iTCP:12121 -sTCP:LISTEN`）
- 从手机/另一台机器测连通性：`nc -vz <电脑IP> 12121`（Windows 可用 `Test-NetConnection <电脑IP> -Port 12121`）
- `adb logcat -s godot:V` 看连接日志

App 是横屏使用；manifest 已固定 `landscape`。

---

## 7. 工程里哪些是“生成”的

| 路径 | 是否进 git | 说明 |
|---|---|---|
| `android/` | ❌ `.gitignore` 的 `/android/` | 由 Godot 构建模板 + 导出生成，约 1.1GB，不要提交 |
| `.godot/` | ❌ | Godot 导入缓存 |
| `*.apk` | ❌ | 构建产物 |
| `export_presets.cfg` | ✅ | 已带 `Android` 预设（包名/ABI/版本/权限） |
| `project.godot` | ✅ | 4.7.2、mobile 渲染、editor plugins |
| `addons/NativeCameraPlugin/bin/{debug,release}/*.aar` | ✅ | 相机插件原生库 |
| `addons/OpenVINSGodot/bin/{debug,release}/*.aar` | ✅ | VIO 插件原生库 |
| `addons/GodotAndroidPluginTemplate/bin/*.aar` | ✅ | 模板插件（默认启用，会随 APK 打包） |
| `addons/zxing-helper.jar`、`addons/core-3.5.4.jar` | ✅ | 二维码扫描依赖 |
| `config/*.yaml` | ✅ | 会被 `include_filter="config/*.yaml"` 打进 APK |

本工程**没有**手工修改 `android/build` 下的 Gradle 文件；  
`build.gradle` / `config.gradle` / `settings.gradle` / `gradle.properties` / 主 Manifest 与 Godot 4.7.2 官方模板一致。  
`src/debug`、`src/release` 的 Manifest 是导出时生成的，不要手改。

NativeCamera / OpenVINS 的 AAR 已经随仓库提交，构建 APK **不需要**重新编译它们。  
只有你要改 OpenVINS 本身时，才需要去 `openvins_work` 重新构建并替换 AAR。

---

## 8. 版本清单（来自 `android/build/config.gradle`）

| 项目 | 版本 |
|---|---|
| Godot | 4.7.2 stable |
| Android Gradle Plugin | 8.6.1 |
| Gradle（wrapper 自动下载） | 8.11.1 |
| Kotlin | 2.1.21 |
| Java | 17 |
| compileSdk | 36 |
| minSdk | 24 |
| targetSdk | 36 |
| Build-Tools | 36.1.0 |
| NDK | 29.0.14206865 |
| ABI | arm64-v8a |
| 包名 | `com.blecaco.mobile` |
| versionCode / versionName | 1 / 1.0 |
| 导出格式 | APK |

如果升级 Godot，必须重新安装对应版本的 Android 构建模板，并同步更新本表。

---

## 9. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `android/` 不存在，导出报模板缺失 | 首次没安装模板。执行第 3 节，或加 `--install-android-build-template` |
| `No export template found` | 没装 4.7.2 Export Templates；编辑器里 `Manage Export Templates` 安装 |
| `Android SDK path is invalid` | Godot Editor Settings 里 SDK Path 没设，或 `ANDROID_HOME` 不对 |
| `Failed to find target with hash string 'android-36'` | 没装 SDK Platform 36；`sdkmanager "platforms;android-36"` |
| `NDK not found` / 版本不匹配 | 装 `ndk;29.0.14206865`，不要用别的版本 |
| `Build-Tools 36.1.0 missing` | `sdkmanager "build-tools;36.1.0"` |
| `Unsupported class file major version` | Gradle 在用 JDK 21+；切到 JDK 17，设好 `JAVA_HOME` |
| Gradle 下载依赖很慢 / 卡住 | 首次构建需联网；检查代理；`cd android/build && ./gradlew --stop` 后重试 |
| Gradle 缓存/模板损坏 | `rm -rf android` 后重新安装模板（见第 3 节） |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 旧包签名不同；先 `adb uninstall com.blecaco.mobile` |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | 当前只打 arm64-v8a；换 64 位 ARM 真机，或改预设加 x86_64（模拟器） |
| 装完还是旧界面 | 装完必须 `adb shell am force-stop com.blecaco.mobile` |
| 手机连不上 Blender | 同一局域网、防火墙 12121、插件服务已启动、IP 正确；`adb logcat -s godot:V` |
| 相机黑屏/打不开 | 检查相机权限；确认 `NativeCameraPlugin` / `OpenVINSGodot` 的 AAR 存在且 editor plugins 没被禁用 |

---

## 10. 附：从零安装 SDK（Linux 命令示例）

如果你没有 Android Studio，可以用 command-line tools：

```bash
# 1) JDK 17
sudo apt install openjdk-17-jdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# 2) command-line tools
# 从 https://developer.android.com/studio#command-tools 下载最新版
mkdir -p "$HOME/Android/Sdk/cmdline-tools"
unzip commandlinetools-linux-*.zip -d "$HOME/Android/Sdk/cmdline-tools"
mv "$HOME/Android/Sdk/cmdline-tools/cmdline-tools" "$HOME/Android/Sdk/cmdline-tools/latest"

export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# 3) 组件
yes | sdkmanager --licenses
sdkmanager \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.1.0" \
  "ndk;29.0.14206865"

# 4) 验证
adb version
sdkmanager --list_installed | grep -E 'android-36|36.1.0|29.0.14206865'
```

> Windows / macOS 的同学：把 `$HOME/Android/Sdk` 换成各自默认路径（Windows 通常是  
> `%LOCALAPPDATA%\Android\Sdk`，macOS 通常是 `~/Library/Android/sdk`），命令语法按对应 shell 调整。

---

## 11. 最短复现步骤（给已经装好依赖的人）

```bash
git clone git@github.com:CantanTam/blecaco_phone.git
cd blecaco_phone

export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

# 首次
godot --headless --install-android-build-template --export-debug "Android" /tmp/Blecaco-debug.apk

adb install -r /tmp/Blecaco-debug.apk
adb shell am force-stop com.blecaco.mobile
```

之后每次改代码只需要：

```bash
godot --headless --export-debug "Android" /tmp/Blecaco-debug.apk
adb install -r /tmp/Blecaco-debug.apk
adb shell am force-stop com.blecaco.mobile
```
