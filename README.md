# blecaco_phone
blecaco phone app for Blender blecaco addon

## 构建 Android

需要 **Godot 4.7.2** + **Android SDK 36 / Build-Tools 36.1.0 / NDK 29.0.14206865** + **JDK 17**。

克隆后 `android/` 不存在（构建模板被 gitignore），首次构建需要安装模板：

```bash
godot --headless --install-android-build-template --export-debug "Android" /tmp/Blecaco-debug.apk
adb install -r /tmp/Blecaco-debug.apk
adb shell am force-stop com.blecaco.mobile
```

完整步骤、Release 签名和排错见 [docs/ANDROID_BUILD.md](docs/ANDROID_BUILD.md)。
