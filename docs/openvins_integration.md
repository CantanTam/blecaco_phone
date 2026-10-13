# 在 mobile 项目中以 addon 形式集成 OpenVINS

本文档给出把 [OpenVINS](https://github.com/rpng/open_vins) 作为 Godot Android
插件（addon）接入 `blecaco_godot/mobile` 的完整操作步骤。

> 前置事实：本机已经存在一份可用的 OpenVINS Android 工程
> `/home/one/open_vins_mobile`（GitHub: `goldbattle/open_vins_mobile`），
> 它已经解决了「OpenVINS 交叉编译 + Camera2 + SensorManager」的全部难题。
> 本文的做法是**复用**它，只新增一个 `:plugin` 库模块把它打包成 Godot 能吃的 AAR，
> 而不是从零交叉编译 OpenVINS。

---

## 1. 架构与数据流

```
┌────────────────────────── Godot (mobile) ──────────────────────────┐
│  addons/NativeCameraPlugin  ──frame_available──┐                   │
│                                                ▼                   │
│  addons/OpenVINSPlugin/OpenVINS.gd  ── feedGray() ──┐              │
│         ▲ pose_updated(VioPose)                     │              │
└─────────┼───────────────────────────────────────────┼──────────────┘
          │ JavaClassWrapper                          │ JavaClassWrapper
┌─────────┴───────────────────────────────────────────▼──────────────┐
│  AAR: com.blecaco.openvins.OpenVINSBridge (Java)                   │
│    - SensorManager(ACCEL+GYRO, FASTEST) ── nativeFeedImu ──┐       │
│                                                           ▼        │
│  libopenvins_jni.so (OpenVINS + JNI bridge, C++) ── VioManager     │
└────────────────────────────────────────────────────────────────────┘
```

关键设计决定（都是被现有代码强制出来的）：

| 问题 | 结论 | 原因 |
| --- | --- | --- |
| 相机帧从哪来 | 继续用 `NativeCameraPlugin`，把帧「喂」给插件 | Android 同一时刻只允许一个 Camera2 会话，插件内部再开一路会和现有扫码/光流相机冲突 |
| IMU 从哪来 | 由 AAR 内部 `SensorManager` 采集 | 需要 **加速度计 + 陀螺仪** 且带 BOOTTIME 时间戳；`NativeCameraPlugin.gyroscope_available` 只有陀螺仪 |
| 怎么暴露给 GDScript | `JavaClassWrapper.wrap(...)` 轮询 | 与本项目 `scripts/qrcode.gd` 里 ZXing 的做法完全一致，不依赖 `org.godotengine:godot` 制品 |
| 时间基准 | Camera2 `SENSOR_TIMESTAMP` 与 `SensorEvent.timestamp` 的 BOOTTIME 纳秒 | 两者同源，这是 VIO 能收敛的前提 |

---

## 2. 涉及的文件

**Godot 侧（本仓库）**

```
mobile/addons/OpenVINSPlugin/
  plugin.cfg              # 插件声明（已在 project.godot 里登记后才生效）
  OpenVINSPlugin.gd       # EditorPlugin：导出期把 AAR 交给 gradle 构建
  OpenVINS.gd             # class_name OpenVINS：运行时节点
  model/VioPose.gd        # class_name VioPose：位姿数据模型
  bin/debug/OpenVINSPlugin-debug.aar       # ← 由构建脚本生成
  bin/release/OpenVINSPlugin-release.aar   # ← 由构建脚本生成
```

**原生侧（`/home/one/open_vins_mobile`）**

```
plugin/
  build.gradle                                  # com.android.library
  sync_to_godot.sh                              # 构建 + 复制 AAR 到上面两个目录
  src/main/AndroidManifest.xml
  src/main/java/com/blecaco/openvins/OpenVINSBridge.java
  src/main/cpp/CMakeLists.txt
  src/main/cpp/openvins_godot_bridge.cpp        # native-lib.cpp 的 Godot 版
```

---

## 3. 阶段 1：构建 Godot 用的 AAR

```bash
cd /home/one/open_vins_mobile

# 一次性：确认 OpenVINS 子模块已拉取
git submodule update --init --recursive   # app/src/main/cpp/open_vins

# 一次性：确认 local.properties 指向本机 SDK（本步骤已为你创建好）
cat local.properties                      # sdk.dir=/home/one/Android/Sdk

# 构建 + 复制 AAR 到 Godot addon
./plugin/sync_to_godot.sh
```

说明：

- 只需要 **arm64-v8a**（`mobile/export_presets.cfg` 里 `architectures/arm64-v8a=true`，
  其余 ABI 为 false），脚本已按此裁剪，避免 AAR 过大。
- 需要本机已安装 **NDK 25.1.8937393**（`plugin/build.gradle` 里的 `ovNdkVersion`），
  与之前 `open_vins_mobile/app` 成功构建时使用的版本一致。
- 首次构建会编译整个 OpenVINS（约几分钟）。产物 AAR 约 30–50 MB
  （内含 `libopencv_java4.so` ≈17 MB、`libc++_shared.so` ≈6.7 MB、
  `libboost_*.so` 若干、`libopenvins_jni.so`）。

---

## 4. 阶段 2：在 Godot 中启用插件

1. 确认 AAR 已就位：

   ```bash
   ls -la /home/one/blecaco_godot/mobile/addons/OpenVINSPlugin/bin/debug/
   ls -la /home/one/blecaco_godot/mobile/addons/OpenVINSPlugin/bin/release/
   ```

2. Godot 编辑器 → **项目 → 项目设置 → 插件** → 勾选 **OpenVINS**。
   勾选后 `mobile/project.godot` 的 `[editor_plugins] enabled` 会自动追加：

   ```
   res://addons/OpenVINSPlugin/plugin.cfg
   ```

   > 本步骤已经替你执行完毕，`project.godot` 现为：
   > ```
   > enabled=PackedStringArray("res://addons/GodotAndroidPluginTemplate/plugin.cfg",
   >     "res://addons/NativeCameraPlugin/plugin.cfg",
   >     "res://addons/gdscript_digit_mapper/plugin.cfg",
   >     "res://addons/OpenVINSPlugin/plugin.cfg")
   > ```

3. 确认导出预设使用 Gradle 构建（当前 `mobile/export_presets.cfg` 已满足）：

   ```
   gradle_build/use_gradle_build=true
   architectures/arm64-v8a=true
   permissions/camera=true
   ```

> 原理：`OpenVINSPlugin.gd` 的 `_get_android_libraries()` 会把
> `OpenVINSPlugin/bin/debug|release/OpenVINSPlugin-debug|release.aar` 交给
> Godot 的 gradle 构建，最终进入 APK 的 `classes.dex` 与 `lib/arm64-v8a/`。
> 这与 `addons/NativeCameraPlugin` 的做法完全一致。
>
> 补充：Godot 生成的 `android/build/build.gradle` 里还有一行
> `implementation fileTree(dir: "$addonsDirectory", include: ['*.jar','*.aar'])`，
> 也就是说**直接放在 `res://addons/` 根目录**下的 jar/aar 会被自动包含
> （本项目里的 `addons/zxing-helper.jar` 就是靠这个生效的）。
> 本插件走的是显式 `EditorExportPlugin` 路线，以便区分 debug/release。

---

## 5. 阶段 3：把标定配置放到手机上

OpenVINS 必须要**每台手机各自标定**，否则位姿会发散或尺度错误。
配置由三个文件组成（`open_vins_mobile/app_device/config/` 里有本机已有的样板）：

- `estimator_config.yaml` —— 估计器参数，其中两项指向另外两个文件：
  - `relative_config_imu: "kalibr_imu_chain.yaml"`
  - `relative_config_imucam: "kalibr_imucam_chain.yaml"`
- `kalibr_imu_chain.yaml` —— IMU 噪声/随机游走、update_rate、模型
- `kalibr_imucam_chain.yaml` —— 相机内参、畸变、`T_cam_imu`、`timeshift_cam_imu`

把三个文件推到设备上的一个目录，例如 App 私有目录：

```bash
PKG=com.example.blecaco          # 换成你实际的包名
DST=/sdcard/Android/data/$PKG/files/openvins/config

adb shell mkdir -p $DST
adb push /home/one/open_vins_mobile/app_device/config/estimator_config.yaml   $DST/
adb push /home/one/open_vins_mobile/app_device/config/kalibr_imu_chain.yaml   $DST/
adb push /home/one/open_vins_mobile/app_device/config/kalibr_imucam_chain.yaml $DST/
```

然后在 GDScript 里把绝对路径告诉节点（包名取自 `export_presets.cfg` 的
`package/unique_name="com.example.$genname"`，本工程实际生成为
**`com.example.blecaco`**）：

```gdscript
openvins.estimator_config_path = "/storage/emulated/0/Android/data/com.example.blecaco/files/openvins/config/estimator_config.yaml"
```

> 若换成新手机，用 `open_vins_mobile` 的原始 App（或本插件的 `record_dataset`）
> 采集一段数据集，再用 `app_kalibr/` 里的 Kalibr Docker 流程重新标定。

---

## 6. 阶段 4：在场景里接线

`OpenVINS` 是普通 `Node`，与现有 `NativeCamera` 配合即可。以 free mode 为例：

```gdscript
extends Node

@onready var camera: NativeCamera = $NativeCamera
var openvins: OpenVINS = OpenVINS.new()

func _ready() -> void:
	# NativeCamera 必须输出「灰度」帧
	camera.is_grayscale = true
	camera.frame_width = 640
	camera.frame_height = 480
	camera.scale_width = 640
	camera.scale_height = 480
	camera.auto_upright = true

	# 分辨率必须与 kalibr_imucam_chain.yaml 里的 resolution 一致
	add_child(openvins)
	openvins.pose_updated.connect(_on_vio_pose)
	openvins.vio_initialized.connect(func(): print("[VIO] initialized"))

	camera.frame_available.connect(openvins.feed_frame)
	openvins.start()      # 使用 estimator_config_path（可用 @export 在检查器里填）

func _on_vio_pose(a_pose: VioPose) -> void:
	var p: Vector3 = a_pose.get_position()
	var q: Quaternion = a_pose.get_orientation()

	# 与现有 free_mode 的坐标系约定一致（参考 blecaco/free_action.py
	# 与 scripts/modes/optical_flow_controller.gd 的轴向关系）后发给 Blender：
	# connection.send_action("free", {"command": "translation", "x": ..., "y": ..., "z": ...})
```

> **重要**：`feed_frame` 要求灰度帧且尺寸 == `width * height`。
> 如果 `NativeCameraPlugin` 输出的 `FrameInfo.get_buffer()` 不是严格
> `width*height` 字节（例如仍带 padding），先在 GDScript 里裁剪再喂。

---

## 7. 阶段 5：验证时间戳（最关键的一步）

VIO 收敛与否，九成取决于相机与 IMU 是否**共享同一时间基准**。
在设备上打印一次并比对：

```gdscript
func _check_timestamp_alignment() -> void:
	var rt := Engine.get_singleton("AndroidRuntime")
	var SystemClock := JavaClassWrapper.wrap("android.os.SystemClock")
	# 单位：纳秒（BOOTTIME）
	var now_ns: int = SystemClock.elapsedRealtimeNanos()
	print("[TS] elapsedRealtimeNanos = ", now_ns)
	# 同时观察 OpenVINS 日志里的相机/IMU 时间戳（见下），数量级应完全一致
```

同时用 logcat 观察原生日志：

```bash
adb logcat -s OpenVINSGodot:V OpenVINSBridge:V
```

- 如果 `FrameInfo.get_timestamp_ns()`（Camera2 `SENSOR_TIMESTAMP`）
  与 `SystemClock.elapsedRealtimeNanos()` 同量级 → 直接用即可。
- 如果相差很大（例如接近 `System.nanoTime()` 的 CLOCK_MONOTONIC，或接近 0）
  → 必须在 GDScript 侧用 `elapsedRealtimeNanos()` 重新打时间戳，
  或修改 `NativeCameraPlugin` 让它输出 `SENSOR_TIMESTAMP`。

另一个可观测的指标是 `kalibr_imucam_chain.yaml` 里的 `timeshift_cam_imu`
（本机样板是 `0.0188`，约 19 ms）。如果估计器把这个值推得越来越大，
基本就是时间戳错了。


---

---

## 8. 本次已实际跑通并验证的部分

以下内容不是「应该能行」，而是本地已经真实构建/导出通过：

| 验证项 | 结果 |
| --- | --- |
| `./gradlew :plugin:assembleDebug/Release` | **BUILD SUCCESSFUL**（OpenVINS 全量交叉编译 arm64-v8a） |
| `libopenvins_jni.so` 导出符号 | 9 个 `Java_com_blecaco_openvins_OpenVINSBridge_native*` + `JNI_OnLoad` 全部存在 |
| AAR 内容 | `classes.jar` + `jni/arm64-v8a/{libopenvins_jni,libopencv_java4,libc++_shared,libboost_*}.so` |
| NDK 依赖（`llvm-readelf -d`） | 仅依赖 `libopencv_java4` + 5 个 boost + `libc++_shared`，已全部打包 |
| GDScript 语法 | `godot --headless --check-only` 对 `OpenVINS.gd` / `OpenVINSPlugin.gd` / `VioPose.gd` 全部无错误 |
| Godot 完整导出 | `godot --headless --export-debug "Android"` **成功**，产出 APK |
| APK 内原生库 | `lib/arm64-v8a/` 下 8 个 OpenVINS 相关 `.so` 全部就位 |
| APK 内 Java 类 | `classes.dex` 中存在 `com/blecaco/openvins/OpenVINSBridge`（且原有 `ZxingHelper` 未受影响） |
| APK 包名 / 权限 | `com.example.blecaco`，含 `android.permission.CAMERA` |

尚未验证（需要真机 + 标定数据）：VIO 实际收敛、位姿精度、时间戳是否同基准。

### 已存在的历史问题（非本次引入）

导出日志里会看到：

```
WARNING: UID duplicate detected between
  res://scripts/modes/optical_flow_controller.gd
  res://scenes/modes/optical_flow_controller.gd
```

`scenes/modes/` 与 `scripts/modes/` 各有一份同名脚本，建议删掉其中一份。


## 9. 注意事项与坑

1. **GPL-3.0 许可**
   OpenVINS 是 GPL-3.0。静态链接进本 App 意味着整个 App 需要以 GPL-3.0
   兼容方式分发（需提供完整源码）。如果这不是你想要的，需要重新评估方案。

2. **APK 体积**
   `libopencv_java4.so`(≈17 MB) + `libc++_shared.so`(≈6.7 MB) +
   `libboost_*.so` + `libopenvins_jni.so` 会显著增大 APK。
   当前 `export_presets.cfg` 里 `gradle_build/compress_native_libraries=false`，
   如在意体积可改为 `true`（代价是启动时解压）。

3. **只有一个 Camera2 会话**
   OpenVINS 用的帧与扫码/光流共用 `NativeCameraPlugin` 的同一路摄像头。
   `scripts/qrcode.gd` 里已有「扫码结束后 `camera.stop()` 释放给光流」的处理，
   接入 VIO 时同样要走这套流程，不要同时 `start()` 两次。

4. **分辨率必须一致**
   `kalibr_imucam_chain.yaml` 的 `resolution` 必须等于实际喂进去的灰度图尺寸。
   样板是 `[640, 480]`，而当前光流用的是 `320×240`——两者不能混用，
   VIO 需要单独一路 640×480 的灰度请求，或重新标定。

5. **首次必须静止初始化**
   默认配置 `init_dyn_use: false`（无 Ceres），走静态初始化：
   启动后需要保持设备静止约 `init_window_time`（1 秒）才能完成初始化。
   `OpenVINS.vio_initialized` 信号触发前不要使用位姿。

6. **`JavaClassWrapper` 的返回值**
   `OpenVINS.gd` 里对 `getPose()` 的返回值做了 `TYPE_PACKED_FLOAT64_ARRAY` 检查。
   如果某些 Godot 版本不把 Java `double[]` 转成 `PackedFloat64Array`，
   可在 `OpenVINSBridge.java` 里改成返回 `float[]`（配合 `PackedFloat32Array`），
   或改用逐分量 getter。这是唯一有版本兼容风险的点。

7. **`NDK` 版本**
   `plugin/build.gradle` 固定使用 `25.1.8937393`。Boost 预编译库是 NDK 21 构建的，
   与 25 混合使用目前可正常工作（`open_vins_mobile/app` 已验证），
   但不要随意升级该版本。

---

## 10. 验收清单

- [ ] `cd /home/one/open_vins_mobile && ./plugin/sync_to_godot.sh` 成功，
      `mobile/addons/OpenVINSPlugin/bin/{debug,release}/*.aar` 存在
- [ ] Godot 插件面板里勾选了 **OpenVINS**（`project.godot` 的 `editor_plugins/enabled` 含之）
- [ ] Android 导出仍勾选 **Use Gradle Build**
- [ ] 真机 logcat 出现 `[OpenVINS] 原生桥接层加载成功` 与 `VioManager created`
- [ ] logcat 出现 `Processing worker thread started`
- [ ] 相机帧时间戳与 `elapsedRealtimeNanos()` 同量级
- [ ] 静止 1 秒后 `vio_initialized` 触发，`pose_updated` 开始有数据
- [ ] 平移手机时 `VioPose.get_position()` 单调变化（不是噪声抖动）
- [ ] Blender 端相机按预期平移/旋转

---

## 11. 后续可做

- 把 `pose_updated` 的位姿接到 `scripts/modes/free_mode.gd`，
  用 VIO 位置替换/融合当前 `optical_flow_controller.gd` 的像素位移估算
  （VIO 提供的是真实尺度位移，且带旋转补偿，精度会显著高于纯光流）。
- 增加一个「VIO 状态」调试 UI，绘制 `getTrajectory()` 返回的轨迹
  （`OpenVINSBridge.getTrajectory()` 已按 `[px,py,pz,qw,qx,qy,qz]` 扁平返回）。
- 若想彻底去掉 GDScript 中转开销，可把本插件升级为真正的
  `GodotPlugin` v2 单例（需要依赖 `org.godotengine:godot:4.7.2.stable`），
  再用信号回调代替轮询。当前轮询方案在 30–60 Hz 下开销可接受。

