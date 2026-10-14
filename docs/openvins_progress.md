clear && adb install -r ~/open_vins_mobile/app/build/outputs/apk/debug/app-debug.apk
￼
# OpenVINS 接入进度与遗留问题（交接笔记）

> 记录日期：2026-10-14 凌晨
> 设备：Xiaomi Redmi 21091116AC (evergo)，Android 13 (SDK 33)，IMU = LSM6DSO
> 目标：用单目 OpenVINS 给出**真实尺度（米）**的平移，替换原本不准的光流位移；
> 旋转继续走陀螺仪，Blender 端行为保持不变。

---

## 1. 现在的状态

### ✅ 已经跑通（均经实测验证）

| 环节 | 证据 |
| --- | --- |
| AAR 打进 APK | `JavaClassWrapper.wrap("com.blecaco.openvins.OpenVINSBridge")` → `bridge_ready=true` |
| 原生 VIO 启动 | logcat `OpenVINSGodot: VioManager created` |
| IMU 采集 | `IMU samples delivered: …`，约 **424 Hz**；`dumpsys sensorservice` 可见两条登记 |
| 相机喂帧 | `[VIO] … frames_ok=…, frames_bad=0`（640×480 灰度，rotation=90） |
| 时钟对齐 | 原生 `diag:` 中 `imu_latest` 与 `now` 仅差约 **5 ms** |
| VIO 初始化 | `[VIO] 初始化完成`，之后 `poses` 持续增长 |
| 位姿送进 Blender | `journalctl` 可见 `{'command': 'translation', 'x': …}`，Blender 侧执行 `world_matrix.translation += world_motion` |

**结论：Godot → Java → OpenVINS → GDScript → WebSocket → Blender 整条链路已打通，且位移是米制。**

### ❌ 唯一遗留问题（**已定位原因并修正，待实测确认**）

**手机静止不动时，VIO 输出的位置仍持续漂移。**

实测（手机平放不动）：22 秒内 z 从 8 m 单调涨到 67 m；每步位移中位数按
`0.096 → 0.496 → 1.538 → 2.661 → 4.724 m` 指数增长。

刚初始化后的头几秒是好的（每步约 0.02 m），之后逐渐发散。

> **根因已找到**：`estimator_config.yaml` 里的观测噪声/卡方门限写错了
> （`up_*_chi2_multipler: 1`、`up_*_sigma_px: 1`，金标准是 `5` / `2`），
> 导致视觉更新被大量拒绝、滤波器退化成纯 IMU 递推。
> 详细对比与修正见第 3 节 —— 修正后**尚未在本机实测验证**。
>
> ⚠️ 修正带来的行为变化：初始化阈值收紧后（`init_imu_thresh: 0.4`、
> `init_max_disparity: 2.0`），**手机必须真正静止（最好放桌上）才会初始化**；
> 拿着手轻微晃动可能一直停在 `init=false`，这不代表故障。

---

## 2. 排查过程中确认 / 排除的事实

### 已修复的坑（都实测确认过）

1. **`JavaClassWrapper` 不能跨语言传 Java 对象**
   把 `Context` 从 GDScript 传进 `start(Context, String)` 会让调用被**静默吞掉**
   （Java 方法体一行日志都不打、返回 null，`bool(null)` 得到 false）。
   改为 Java 侧自己反射解析 Context —— `startWithConfig(String)`。

2. **Android 12+ 的 `HIGH_SAMPLING_RATE_SENSORS` 权限**
   `targetSdk=36` 时，用 `SENSOR_DELAY_FASTEST`（>200 Hz）注册传感器会抛
   `SecurityException`；被 JavaClassWrapper 吞掉后表现为"IMU 永远没注册上"。
   已在 AAR 的 `AndroidManifest.xml` 与 `export_presets.cfg` 的
   `permissions/custom_permissions` 双保险声明；代码里也加了捕获后退到 100 Hz 的兜底。

3. **`HandlerThread.getLooper()` 竞态**
   `start()` 后立刻 `getLooper()` 可能返回 null → `new Handler(null)` 抛 NPE。
   现在用 `waitForLooper()` 轮询等待。

4. **`startImu()` 的"毒化状态"**
   原来只要 `sensorManager != null` 就认为"已注册"，中途抛异常会让后续调用
   永远跳过真正的注册。现在要求四个字段齐备，且**注册成功后才提交静态状态**。

5. **`SensorEvent` 对象由系统复用**
   原来保存 event 引用做 accel/gyro 配对，可能读到另一路的数据。
   现在把 `values` 拷贝到自己的缓冲区。

6. **日志刷屏冲掉 logcat 环形缓冲区**
   `connection.gd` / `free_mode.gd` 在 ~100 Hz 打印全文，十几秒就写满缓冲区，
   关键启动日志会消失、白绕一圈。已用 `VERBOSE_SEND_LOG` /
   `VERBOSE_ORIENTATION_LOG` 默认关闭；也可用 `adb logcat -G 16M` 扩容。

### 已排除（有证据）

- **IMU 没数据**：已确认 424 Hz 稳定流入。
- **帧尺寸 / 格式不对**：`buffer.size()==width*height`；dump 出的 PNG 是正常图像
  （`min=2 max=254 mean=96.8`，画面可辨识、无错位）。
- **时钟不同源**：`imu_latest` 与 `now` 差约 5 ms。
- **队列堆积**：`front_age` 常态 0.06~0.15 s。
- **IMU 噪声参数**：`kalibr_imu_chain.yaml` 已按 OpenVINS 建议把 datasheet 值放大 10 倍。
- **`T_imu_cam` 语义**：OpenVINS 自带配置的注释确认它就是
  `rotation from camera to IMU (R_CtoI)`，与我们的写法一致。

---

## 3. 明天从这里继续

### 🔑 最重要的一条：仓库里有「金标准」配置，不要再自己推导

`/home/one/open_vins_mobile/app_device/config/` 是**本项目在真机上实测跑通**
（能初始化、能出轨迹）的配置，配合 `app_device/sync_device.sh` 推到手机上。
**它不针对某一台手机特调**，是通用可用的起点。

已逐项 diff 并**对齐**到我们的 `addons/OpenVINSPlugin/config/estimator_config.yaml`
（参考 73 个键，现在只剩 `record_timing_filepath` 一处差异，而该项在
`record_timing_information: false` 下不生效）。

修正的关键差异（这些是「静止时位置指数发散」的**直接原因**）：

| 键 | 金标准 | 我们原来 | 后果 |
| --- | --- | --- | --- |
| `up_msckf_chi2_multipler` | 5 | 1 | 卡方门限紧 5 倍 → 视觉更新被大量拒绝 |
| `up_msckf_sigma_px` | 2 | 1 | 残差归一化后更大 → 更易被拒 |
| `up_slam_sigma_px` / `chi2` | 2 / 5 | 1 / 1 | 同上 |
| `init_imu_thresh` | 0.4 | 1.5 | 阈值太松 → 手还在动就"初始化完成" |
| `init_max_disparity` | 2.0 | 10.0 | 同上 |
| `init_window_time` | 1.0 | 2.0 | — |
| `init_max_features` | 25 | 50 | — |
| `track_frequency` | 31.0 | 21.0 | 需与相机 ~30fps 匹配 |
| `num_opencv_threads` | 1 | 4 | 手机上单线程更稳 |
| `zupt_noise_multiplier` 等 | 50 / 1.5 / true | 10 / 0.5 / false | `try_zupt=false` 时不生效，纯对齐 |

**机制**：`chi2_multipler` 越小门限越窄、`sigma_px` 越小残差越大，
两者叠加使几乎所有视觉更新被拒绝 → 滤波器退化成**纯 IMU 递推** →
速度/位置指数发散，正好解释了观测到的现象。

### 顺带确认的好消息

- **相机-IMU 外参我推导对了**：金标准里 `T_cam_imu` ≈ `[[0,-1,0],[-1,0,0],[0,0,-1]]`
  （带 Kalibr 标定残差），与我们配置的 `T_imu_cam` 一致。
- OpenVINS 的 `opencv_yaml_parse.h` **两种 key 都接受**且视为同一矩阵
  （`T_cam_imu` ↔ `T_imu_cam` 互为 fallback），所以键名不影响结果。

### 仍与金标准不同、且已知的一处

金标准用 `Camera2ResView.kt` 里的 **`image.timestamp`（Camera2 SENSOR_TIMESTAMP，
真实曝光时刻）**；我们用 GDScript 收到帧的**到达时刻**。
这是唯一还没对齐的输入差异，见下一节。

---

## 3.1 2026-10-14 上午：对齐金标准配置后的新发现（最新）

#### 3.1.1 配置已对齐，但**问题变了**

对齐 `app_device` 的 12 个值后（提交 `30ba745`），行为发生了实质变化：

- ✅ **现在能初始化了**：`init=true`，`poses` 持续增长
- ✅ **在线标定收敛**，数值都合理：
  ```
  camera-imu timeoffset = -0.03951 s        ← 估计出 -39.5 ms（与"到达时刻"晚于曝光一致）
  cam0 intrinsics = 520.7, 511.1, 306.6, 239.0 | -0.043,-0.003,-0.011,0.008
  cam0 extrinsics = -0.711,0.702,0.028,0.026 | ...   ≈ [[0,-1,0],[-1,0,0],[0,0,-1]] ✅ 初值是对的
  bg = 0.0229,-0.0010,0.0032 | ba = -0.0654,-0.1725,0.1871   ← 偏置很小，健康
  ```
- ❌ **但轨迹仍然爆炸**：手机静止时位置一路涨到 **53 公里**（`dist = 53128 m`）

#### 3.1.2 发散形态已定量确认：**是重力没被抵消**

从心跳提取位置序列做拟合（`poses` 近似正比于时间）：

```
poses=  19   |p| =      0.02 m
poses=1625   |p| =     37.94 m
poses=3181   |p| =   1046.78 m
poses=5217   |p| =  10096.72 m
poses=7757   |p| =  44680.44 m

线性拟合 |p| ≈ 5.5·t          残差 6.96e9
二次拟合 |p| ≈ 1.384e-3·t²    残差 3.54e8   ← 明显更优
```

`poses` 约 54/秒 ⟹ **加速度 ≈ 8.1 m/s²，几乎就是 g=9.81**。

**结论：姿态（重力方向）没有被正确估计，重力被当成线性加速度积分了。**
而 `ba` 只有 0.19 m/s²，所以**不是加计偏置问题，是初始姿态问题**。

#### 3.1.3 顺带挖到的两个关键事实

**① OpenVINS 的内部日志一直在 logcat 里，tag 是 `OpenVINS`（不是 `OpenVINSGodot`）**

```bash
adb logcat | grep 'OpenVINS('
```

这条以后是排查的主武器，能直接看到：
`[init]: disparity is ...`、`[init]: failed static init: ...`、
以及标定收敛值（extrinsics / intrinsics / timeoffset / biases）。

**② App 会在约 2 分钟后被一个 Eigen 断言崩溃杀掉**

```
signal 6 (SIGABRT)
Eigen/src/Core/Block.h:147: assertion "startRow >= 0 && blockRows >= 0 && ..." failed
#02 ov_core::FeatureHelper::compute_disparity(...)
```

源码位置 `ov_core/src/feat/FeatureHelper.h`，两处重载都有同样的隐患：

```cpp
for (size_t idx = 0; idx < feat.second->timestamps.at(camid).size(); idx++) {   // ← 用 timestamps 的长度
    ...
    uv0 = feat.second->uvs.at(camid).at(idx).block(0, 0, 2, 1);                 // ← 去索引 uvs，且假定 >= 2 个元素
```

`uvs` 与 `timestamps` 一旦短暂不同步，或某个 uv 向量长度 < 2，
`.block(0,0,2,1)` 就会触发 Eigen 断言 → **整个 App SIGABRT**。
修法很短（加边界判断 + `head<2>()`），但属于**改动 vendored OpenVINS**，需要确认后再动。

#### 3.1.4 与参考实现逐项对比后的结论

| 项目 | 参考实现 | 我们 | 判断 |
| --- | --- | --- | --- |
| 相机-IMU 外参 | `T_cam_imu ≈ [[0,-1,0],[-1,0,0],[0,0,-1]]` | 同 | ✅ 一致 |
| 图像朝向 | 直接用原始 sensor 朝向（不旋转） | 同（`rotation=90` 只是元数据） | ✅ 一致 |
| IMU 配对逻辑 | accel+gyro 配对后一次投递 | 同 | ✅ 一致 |
| JNI 参数顺序 | `(ax,ay,az,gx,gy,gz,t)` | 同 | ✅ 一致 |
| IMU↔加速度赋值 | `wm`←gyro, `am`←accel | 同 | ✅ 一致 |
| **相机时间戳** | **`image.timestamp`（SENSOR_TIMESTAMP）** | GDScript 收到帧的**到达时刻** | ❌ **不一致** |
| **传感器回调线程** | 主线程（不传 handler） | 专用 `OpenVINSImu` 线程 | ⚠️ 不一致 |

> ⚠️ **线程问题值得重视**：OpenVINS 的 ROS 节点是**单线程**喂数据的，其
> `feed_measurement_imu` 与 `feed_measurement_camera` 都会调用
> `propagator->propagate_and_clone(state, …)`。我们现在 IMU 在
> `OpenVINSImu` 线程、相机在 worker 线程**并发**调用，这是上游设计里
> 不存在的竞态，可能破坏状态（并解释那个 Eigen 崩溃）。

#### 3.1.5 接下来的候选动作（按信息量排序）

1. **把 IMU 也改由 worker 线程统一喂**（IMU 先进队列），彻底消除竞态
   —— 同时很可能顺带解决那个 Eigen 崩溃。
2. **导出原始 IMU 数据核对**：把 `setRecording(true)` 接到 GDScript，
   跑一次拿到 `imu0.csv`，离线确认加速度计的量级/符号/单位是否正常，
   直接判定"初始姿态为何错"。
3. **相机时间戳换成 `SENSOR_TIMESTAMP`**（需要 `NativeCameraPlugin` 源码）。
4. **跑一遍参考 App 做交叉验证**：如果它在同一台手机上静止时也漂，
   说明问题不在我们的胶水层；如果它稳，就继续逐项 diff。


## 3.2 剩余待办（按性价比排序）

### ① 真实曝光时间戳（唯一的输入差异）

`OpenVINS.gd._now_seconds()` 用 `SystemClock.elapsedRealtimeNanos()`，
即 **GDScript 收到帧时**取值，**不是** `SENSOR_TIMESTAMP`。
二者相差整个相机管线延迟，Xiaomi/MTK 上可能几十到上百毫秒且有抖动。

- `calib_cam_timeoffset` 只能吸收**恒定**偏差，吸收不了抖动。
- 想根治需要给 `NativeCameraPlugin` 打补丁把 `SENSOR_TIMESTAMP` 透出来。
  ⚠️ 目前 `addons/NativeCameraPlugin/` 里**只有 `bin/*.aar`，没有 Java 源码**，
  需要先拿到该插件的源码工程/仓库。

### ② `timeshift_cam_imu` 初值

金标准是 `0.018778 s`（Kalibr 实测），我们是 `0.0`。
**但金标准是配 SENSOR_TIMESTAMP 测的**，而我们的时间戳晚了一个管线延迟，
两者不能直接照抄 → 先保持 0，等 ① 解决了再一起定。

### ③ 畸变与内参

- 金标准的畸变有真实值 `[0.0413, -0.0350, -0.0011, 0.0022]`，我们是全 0。
  但那是**另一台手机**标出来的，直接抄未必对；我们保留自己的 HAL 内参 + 0 畸变，
  依靠 `calib_cam_intrinsics: true` 在线估计。
- 若 ① 之后仍有偏差，可考虑用 `app_kalibr/` 里的 Docker 流程给本机做一次 Kalibr 标定。

### ④ 其它低优先级

- `p_CinI` 平移（金标准实测 ~1e-5 m，实际就是 0，我们也是 0 ✅）
- IMU 噪声：我们用 datasheet×10，金标准用 EuRoC 典型值；两者都在合理范围
- `init_dyn_use=false`（静态初始化）是否适合手持场景

### ⑤ 效率工具（可选，若要大规模调参再做）

桥接层已具备录制能力（`OpenVINSBridge.setRecording(true)` → Kalibr 格式
`cam0/*.png` + `imu0.csv`），但 `OpenVINS.gd` 没暴露。
加一个「录制 + 回放」通道后，配置试验就能无人值守批量跑，
不必每次都让你重新扫码、举手机。

---

## 4. 调试工具箱（省时间用）

```bash
# --- 构建 AAR 并复制到 addon ---
cd /home/one/open_vins_mobile && ./plugin/sync_to_godot.sh

# --- 导出 & 安装 ---
cd /home/one/blecaco_godot/mobile
godot --headless --export-debug "Android" /tmp/app.apk
adb install -r /tmp/app.apk

# --- 手机日志：只看 Godot 的 print ---
adb logcat -G 16M                 # 先把环形缓冲区扩到 16 MiB（默认很小，会被刷屏冲掉）
adb logcat -v time -s godot:V     # 心跳：[VIO] bridge_ready=… init=… poses=…

# --- Java / 原生层 ---
adb logcat -v time | grep -E 'OpenVINSBridge|OpenVINSGodot'

# --- Blender 收到了什么（Blender 的 stdout 在 user journal 里！） ---
journalctl --user -n 2000 --no-pager | grep -a "blecaco"

# --- 取回喂给 VIO 的那一帧灰度图 ---
adb shell run-as com.example.blecaco cat files/vio_frame.png > /tmp/vio_frame.png
```

### 日志判据速查

| 心跳字段 | 含义 |
| --- | --- |
| `bridge_ready=false` | AAR 没打进 APK / 类名包名不对 |
| `running=false` | `start()` 失败，去看 `OpenVINSBridge` 标签 |
| `frames_ok` 不涨 | 相机没在喂帧（`feed_frame` 在 `_running` 为假时直接 return） |
| `init=false` 而 `frames_ok` 在涨 | 仍在等静止初始化（正常，通常 5~60 s） |
| `poses=0` 且 `init=true` | 检查 `getPose()` 的返回值类型 |

### 原生诊断日志（本次新增）

```
diag: q=2 front_age=0.090 imu_latest=29946.981 imu_inC=29946.981 now=29946.983 dt_off=0.0000 init=0
fed camera #300 ts=29927.914 age=0.127 feats=0 dt_off=0.0000 init=0
```

- `imu_latest` vs `now`：时钟对齐情况（正常应差 <10 ms）
- `front_age`：队列中最老帧的年龄（正常 < 0.5 s）
- `feats`：`get_good_features_MSCKF().size()`。**只在初始化之后才有值**，
  初始化前恒为 0 属正常，不要误判成"跟踪失败"。
- `dt_off`：OpenVINS 在线估计的相机-IMU 时间偏移（只在初始化后才会变动）

---

## 5. 相关文件

| 文件 | 作用 |
| --- | --- |
| `mobile/addons/OpenVINSPlugin/` | Godot addon：`OpenVINS.gd`（GDScript 封装）、`model/VioPose.gd`、`bin/{debug,release}/*.aar`、`config/*.yaml` |
| `mobile/scripts/modes/free_mode.gd` | 接线处：VIO 相机 640×480 灰度 + 陀螺仪旋转 + 位移发送 |
| `mobile/scripts/autoload/options.gd` | 全局配置（模式场景、设置项） |
| `mobile/docs/openvins_config/` | 标定配置**模板**（改完要同步到 addon 的 `config/`） |
| `mobile/docs/openvins_integration.md` | 集成步骤 + 已知坑（含本次新增的第 8~10 条） |
| `/home/one/open_vins_mobile/` | AAR 源工程（`plugin/` 是本次新增的 Godot AAR 模块） |
| `blecaco/free_action.py` | Blender 端：把收到的位移加到相机 `world_matrix.translation` |

