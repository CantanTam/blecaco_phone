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

### ❌ 唯一遗留问题

**手机静止不动时，VIO 输出的位置仍持续漂移。**

实测（手机平放不动）：22 秒内 z 从 8 m 单调涨到 67 m；每步位移中位数按
`0.096 → 0.496 → 1.538 → 2.661 → 4.724 m` 指数增长。

刚初始化后的头几秒是好的（每步约 0.02 m），之后逐渐发散。

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

### 最高优先级：确定相机-IMU 外参的旋转

目前配置里是 `R_CtoI = [[0,-1,0],[-1,0,0],[0,0,-1]]`（**候选 B**）；
历史上还用过 `[[0,1,0],[1,0,0],[0,0,-1]]`（**候选 A**）。
**两个候选都曾让 VIO 成功初始化，之后都发散**，所以目前尚无定论。

已掌握的硬证据：

- 把喂给 VIO 的灰度帧 dump 成 PNG 后逐张看过：缓冲区内容需要**逆时针转 90°**
  才是"世界正立"（转完后显示器标题栏 `blecaco.png`、状态栏、任务栏文字全部可读）。
- 硬件探针实测 `SENSOR_ORIENTATION = 90`（含义是"顺时针转 90° 才正立"）。
- 这两条在"手机以自然朝向（竖屏）握持"的前提下**互相矛盾（差 180°）**，
  说明中间还有一个没弄清的环节 —— 例如插件对 `rotation` 参数的处理方式、
  或 App 是否锁定横屏导致"正立"的参照系不同。

**建议的定论方法（不靠猜）：**

1. 让手机绕**光轴**（正对屏幕的方向）缓慢旋转 90°，同时对比
   `[Orientation]` 送给 Blender 的**陀螺仪姿态** 与 `VioPose.quat` 的变化方向；
   两者一致的那个候选就是对的。
2. 或者更直接：沿手机 X 轴平移一段**量好的距离**（如 30 cm），
   看 Blender 相机是否沿预期轴移动约同样的距离（错误的旋转会串轴）。

### 次高优先级：相机时间戳仍是"到达时刻"

`OpenVINS.gd._now_seconds()` 用的是 `SystemClock.elapsedRealtimeNanos()`，
即在 **GDScript 收到帧时**取值，**不是** Camera2 的 `SENSOR_TIMESTAMP`（真实曝光时刻）。
二者相差整个相机管线延迟，Xiaomi/MTK 上可能几十到上百毫秒且有抖动。

- `calib_cam_timeoffset` 只能吸收**恒定**偏差，吸收不了抖动。
- 想根治需要给 `NativeCameraPlugin` 打补丁，把 `SENSOR_TIMESTAMP` 透出来。
  ⚠️ 目前 `addons/NativeCameraPlugin/` 里**只有 `bin/*.aar`，没有 Java 源码**，
  需要先拿到该插件的源码工程/仓库。

### 其它待验证项

- `kalibr_imucam_chain.yaml` 的**畸变系数全是 0**（radtan）。手机镜头边缘畸变不小，
  可能影响几何一致性 → 可考虑填入典型初值，或让 `calib_cam_intrinsics` 更快收敛。
- `p_CinI`（相机在 IMU 中的位置）仍是 0；真实值只有几毫米，影响较小。

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

