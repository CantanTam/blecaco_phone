# Blecaco 开发进度交接笔记

> **用途**：新开对话时把本文档**整段粘进上下文**当固定前缀。
> 它自包含（今天改了什么 / 为什么 / 实测数据 / 待办 / 验证方法 / 踩过的坑），
> 可以直接接着干活，不需要重新翻代码。
>
> 记录日期：2026-10-14

---

## 0. 今天的改动清单

### App 侧（`mobile/`，git 仓库在 `mobile/.git`）

| 文件 | 行数 | 改动摘要 |
|---|---|---|
| `scripts/modes/optical_flow_controller.gd` | 1100 | **算法重写**：金字塔 + 角点 + SAD 块匹配 + 亚像素 + FB 校验 + RANSAC 4DOF 相似变换 |
| `scripts/optical_flow_test.gd` | 155 | 改为复用上面的实现（原来内含一份旧算法副本，会误导真机判断） |
| `scripts/modes/plane_mode.gd` | 213 | 发送频率自适应 Blender 输出帧率；姿态+前进**合并成一条消息**；加速度斜坡；方向翻转 |
| `scripts/modes/plane_forward_area.gd` | 285 | **表现层集中**：遮罩 / 颜色分段 / 速度分段 / 触控检测；只对外暴露 `forward_speed` |
| `scripts/modes/free_mode.gd` | — | 发送频率同样自适应 |
| `scripts/getrotation.gd` | 257 | **One Euro 四元数平滑**（所有模式共用） |
| `scripts/options.gd` | 210 | 新增 `blender/output_fps`、`record/smoothness` |
| `scripts/main.gd` | — | 接收插件推来的 `setting/output_fps` 并写进 `Options` |
| `scripts/connection.gd` | — | 新增 `action_sending_changed(enabled)` 信号 |
| `scenes/modes/plane_mode.tscn` | — | 材质参数全部移出场景（消除"场景覆盖 shader"的坑） |
| `resources/plane_touch_glow.gdshader` | 新增 | 指尖光晕圆（径向渐变 ∩ 形状遮罩） |
| `resources/plane_mask.gdshader` | 新增 | 纯形状遮罩（箭头底色用） |

### Blender 插件侧（`blecaco/`，git 仓库在 `blecaco/.git`）

| 文件 | 改动摘要 |
|---|---|
| `plane_action.py` | 前进改为**只写 `location`**（修正旋转卡顿）；一条消息同时处理姿态+前进 |
| `free_action.py` | 同样修掉 `matrix_world` 写法；逐条旋转日志改成开关 |
| `setting.py` | 录制加**帧号守卫**（关键性能修复）；输出帧率同步给手机；LINEAR 插值开关 |
| `streamer.py` | 收信逐条 print 改成开关 |

> **注意**：`mobile/` 和 `blecaco/` 是**两个独立的 git 仓库**，`blecaco_godot/` 根目录不是仓库。
> 回退要分别 `cd mobile && git checkout ...` / `cd blecaco && git checkout ...`。

---

## 1. 光流控制器（`mobile/scripts/modes/optical_flow_controller.gd`）

### 1.1 旧实现为什么"效果非常差"（已全部修掉）

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | `SEARCH_RADIUS = 4`，搜索范围只有 ±4px | 正常持机走动每帧位移 5~20px，一超出必然匹配失败 → 输出长期为 0 或乱跳 |
| 2 | 用"块内 max-min 对比度"筛特征 | 排不掉只有单方向梯度的**边缘**（孔径问题），大量单向约束把中位数拉偏 |
| 3 | 整数位移取中位数、无亚像素 | ±0.5px 量化抖动 |
| 4 | 无任何误匹配剔除（`cost/area ≤ 45` 就收） | 大量错误匹配进入结果 |
| 5 | **径向运动 = 以画面中心做投影** | 横向平移本身就会产生巨大"径向"分量 → **前进/后退通道基本是噪声**（最根本的缺陷） |
| 6 | 无金字塔、无预测、无丢失处理 | 大位移 + 死区 = 静默输出错误值 |

### 1.2 新方案

```
3 层金字塔(L0 320×240 / L1 / L2)
  → 最粗层 Shi-Tomasi 最小特征值挑角点 + 网格均匀化
  → 由粗到细 SAD 块匹配（大步长粗扫 → 逐像素精扫，带上一帧模型预测）
  → SAD 曲面抛物线拟合 → 亚像素
  → 双向一致性校验 + 代价门限
  → RANSAC + 最小二乘拟合 4 自由度相似变换
        u = tx + p*(x-cx) - q*(y-cy)
        v = ty + q*(x-cx) + p*(y-cy)
  → 自适应时间滤波 + 死区 + 异常帧拒收
```

**关键突破**：`(tx, ty)` 是**剔除旋转/缩放后的真实平移** → 发给 Blender 的 `x`/`y`；
`p`（膨胀率）**直接就是前进/后退**（取代了有缺陷的中心径向投影）；`q` 是滚转。

**对外协议完全没变**：`x` / `y` / `radial` + `mode="free"`，`blecaco/free_action.py` 不用改。

### 1.3 修掉的越界崩溃

曾经报：`_sad: Out of bounds get index '78118' (on base: 'PackedByteArray')`。

根因：`_match_at_level()` 的两个提前返回分支会返回**未裁剪的预测值**，
被 `_track_l0()` 逐层乘以层级缩放系数放大，最后在代价门限里越界读取。

四层修复：① 提前返回一律走 `_clamp_disp()`；② 代价门限调用前**证明**两个块都在图内，否则丢帧；
③ `_predict_flow()` 用 `.limit_length(MAX_FLOW_PX)`；④ 新增 `|q|*cx > MAX_FLOW_PX` 异常帧拒收。

### 1.4 关键常量（都在文件顶部）

```gdscript
PYRAMID_LEVELS=3  DETECT_LEVEL=2  COARSE_LEVEL=2
BLOCK_RADII=[2,1,1]   SEARCH_RADII=[2,2,3]   COARSE_STEP=2
MAX_FEATURES=36  FEATURE_CELL=8  SHI_TOMASI_RATIO=0.02  FEATURE_MARGIN=5
MAX_MEAN_ABS_DIFF=40.0  FB_MAX_ERROR=1.0
RANSAC_ITERATIONS=48  RANSAC_INLIER_DIST=1.2  RANSAC_MIN_BASELINE=16.0
MIN_INLIERS=8  MAX_FLOW_PX=60.0
FLOW_SMOOTHING_ALPHA=0.35  FLOW_DEADZONE_PX=0.3  LOST_DECAY=0.5
```

### 1.5 实测（本机桌面 CPU / Godot 4.7.2 headless）

```
每帧总耗时   : 17.49 ~ 18.44 ms   （金字塔 3.6 / 角点检测 4.4）
特征点数     : 36
数值精度     : translate(3,-2)   → (3.01, -2.02)
               translate(11,7)   → (11.01, 6.99)      ← 金字塔大位移生效
               expand p=0.015    → 0.0147
               roll  q=0.01      → 0.0102
               RANSAC + 6 个粗大外点 → 仍精确恢复真值，内点 32/32
崩溃回归     : 病态模型(q=5.0) / 极端位移(40px) / 无关画面 全部不崩
```

手机上大概再打 2~3 折（约 20~28 Hz）；后台线程只取最新帧、自动丢帧。

### 1.6 真机调参入口

跟丢频繁 → 加大 `SEARCH_RADII[2]`；手机发烫/掉帧 → 降 `MAX_FEATURES`；
静止还抖 → 加大 `FLOW_DEADZONE_PX`；排查 → `DEBUG_FLOW_LOG = true`。
Blender 端手感仍由 `free_action.py` 的 `move_scale_ratio` / `FLOW_PIXEL_TO_BLENDER_UNITS` 控制。

### 1.7 已知局限

**俯仰/偏航造成的整幅匀流与真实横向平移在数学上不可区分**，纯视觉无解，需要 IMU 前馈。
（工程里已有 `scripts/getrotation.gd` 可提供姿态，尚未接入光流。）

---

## 2. Plane 模式（`plane_mode.tscn` 相关）

### 2.1 职责划分（刻意拆开的）

| 文件 | 职责 | 对外接口 |
|---|---|---|
| `scripts/modes/plane_forward_area.gd` | **表现层**：遮罩 / 颜色 / 大小 / 渐变 / 触控检测。**一条数据都不发** | 只暴露 `forward_speed: float`（带符号倍率，0 = 没按/已暂停） |
| `scripts/modes/plane_mode.gd` | **数据层**：把姿态 + 前进量合并成一条消息发给 Blender | `send_action("plane", {...})` |
| `plane_mode.tscn` | 只留节点结构，**`shader_parameter` 零出现** | — |

### 2.2 消息格式（已合并，消息量减半）

```json
{"type":"action","mode":"plane",
 "data":{"x":..,"y":..,"z":..,"w":..,"forward":0.0167}}
```

* `forward` 带符号：**正数 = 沿相机局部 -Z 前进**，**负数 = 沿 +Z 后退**（由 `plane_action.py::_move_forward` 实现）
* 每秒位移 = `plane_speed × PLANE_MOVE_SPEED_MULTIPLIER(5.0)` → **1x = 5 Blender 单位/秒（≈5 m/s）**
* 发送频率 = `clampf(Options["blender/output_fps"], 60, 120)` Hz，**自适应 Blender 输出帧率**
* `_forward_step() = 1/发送频率`，所以**速度与帧率无关**

### 2.3 速度分段（`plane_forward_area.gd`）

坐标基准：**区域底边为 y=0，向上为正**。

```gdscript
const SPEED_Y_LIMITS := [170.0, 370.0, 515.0, 610.0]
const SPEED_VALUES := [-4.0, -2.0, 1.0, 3.0, 9.0]
```

| 手指高度 | 方向 | 速度 |
|---|---|---|
| 0 ~ 170（区域底部 ▼） | 后退 | 4x |
| 170 ~ 370 | 后退 | 2x |
| 370 ~ 515 | 前进 | 1x |
| 515 ~ 610 | 前进 | 3x |
| 610 以上（区域顶部 ▲） | 前进 | 9x |

> ⚠️ **今天在这踩过一次**：最初我按你写的"运动方向：-z / z"字面对应 Blender 的局部 -Z/+Z，
> 结果前后反了。现在以"前进/后退"为准，**若还要翻，改 `SPEED_VALUES` 整行的符号即可**。

### 2.4 加速度效果（`plane_mode.gd`）

```gdscript
const SPEED_RAMP_PER_SECOND: float = 18.0     # 单位：倍率/秒
func _ramp_speed(delta): _current_speed = move_toward(_current_speed, forward_area.forward_speed, SPEED_RAMP_PER_SECOND * delta)
```

* 放在**发送节流之前** → 每帧都推进，松手 / 暂停时**平滑减速**而不是硬停
* 换向自动经过 0（+4x → -9x 会先停住再反向）
* 实测：`0→9x` 用 30 帧 = 0.500 秒；`-4x→+9x` 用 44 帧 = 0.733 秒（与理论吻合）
* 想更跟手调大（25~30），更沉稳调小（10~12）

### 2.5 圆形颜色分段 + 光晕（`plane_forward_area.gd` + `plane_touch_glow.gdshader`）

同样以区域底边为 y=0：

```gdscript
const COLOR_GREEN/YELLOW/RED
const Y_GREEN_END=350.0   Y_GREEN_TO_YELLOW=515.0   Y_YELLOW_END=610.0   Y_YELLOW_TO_RED=710.0
```

绿(0,1,0) → 350 起渐变到黄(1,1,0) → 515~610 纯黄 → 610 起渐变到红(1,0,0) → 710 以上纯红。
用 `Color.lerp` 表达，与"R=(y-350)/165 / G=1-(y-610)/100"逐位等价。

**可调变量**：`@export circle_size`(直径 px) / `circle_alpha`(整体透明度) / `gradient_start`(0=圆心起渐变,1=圆周才起) / `base_color` / `base_pressed_alpha`。

**shader 结构**：`plane_touch_glow.gdshader` = 径向渐变 **∩** 形状遮罩（都由脚本写入参数）；
`plane_mask.gdshader` = 纯形状遮罩，给箭头底色 `ForwardBottomColor` 用。

> ⚠️ **只有 `.gdshader` 文件里的 uniform 默认值 + 脚本 `@export` 生效**。
> 场景里**绝对不能**再出现 `shader_parameter/xxx`（今天被它坑过两次：改了 shader 没反应）。

### 2.6 暂停发送（LinkButton）的行为

`LinkButton` 只做一件事：`connection.set_action_sending_enabled(false)` → `send_json()` **静默丢弃**所有 `type=="action"` 的消息
（`setting` 类型和视频流不受影响）。它**不会断开 WebSocket**。

现在 `PlaneForwardArea` 会订阅 `Connection.action_sending_changed`，
暂停时**只显示最基本的 `ForwardBottomColor`**（无光晕、不变量实心），
`forward_speed = 0`；松开后若手指仍按着会**自动恢复**。

### 2.7 实测（真实 main.tscn + 挂载 plane 模式）

```
档位映射 10 个采样点（含全部边界值）：全部 OK
实际发出：y=100 → forward_distance = -0.066667（后退）
          y=660 → forward_distance = +0.150000（前进）
暂停：action_sending_enabled=false → forward_speed=0、底色 alpha=0.1176（原样）、光晕隐藏
恢复：手指还按着 → forward_speed 自动恢复
```

---

## 3. 姿态平滑（`mobile/scripts/getrotation.gd`，所有模式共用）

**One Euro Filter，直接作用在四元数上**（用 `slerp`，不是分量 lerp —— 分量 lerp 会一顿一顿，遇 `q/-q` 直接算废）。

强度来自 `Options["record/smoothness"]`（**0.0 ~ 1.0，0 = 完全旁路**，默认 0.5）。

```gdscript
SMOOTH_MIN_CUTOFF_HZ=0.5    SMOOTH_MAX_CUTOFF_HZ=30.0    SMOOTH_BETA=0.12
SMOOTH_DERIVATIVE_CUTOFF_HZ=1.0   SMOOTH_MAX_DT=0.1   SMOOTH_SPEED_DEADBAND=10.0
```

* 截止频率随角速度自适应：**慢 → 强滤（静止不抖）；快 → 几乎不滤（不迟到、不削峰）**
* 速度估计用**上一帧原始输入**（One Euro 的定义），不能用滤波输出（会越滤越迟滞）
* 含符号对齐、归一化、dt 上限；`calibrate()` / `clear_calibration()` 会重置滤波器
* **速度死区必须有**：±0.6° 噪声在 16.7ms 内相当于 36°/s 的"瞬时角速度"，会被误判成快速运动

实测（合成 ±0.6° 噪声，指标 = 帧间跳动）：

| smoothness | 静止 | 25°/s | 90°/s |
|---|---|---|---|
| 0 | 1.4x | 1.4x | 1.3x |
| 0.5 | 3.3x | 3.0x | 1.9x |
| 1.0 | **6.6x** | 4.5x | 2.2x |

迟滞换算成**时间**才有意义：25°/s → 55ms；90°/s → **17ms**（越快时间迟滞越小 = 自适应生效）。

**同时作用于手机预览与录制动画**（同一条数据流），这是想要的效果。
只平滑旋转、不平移（plane 的匀速前进不受影响）。

---

## 4. Blender 插件端（`blecaco/`）

### 4.1 旋转卡顿的真正原因（**已修**）

症状：plane 模式下，**只在按下前进时**摄像头旋转会卡顿。

根因在 `plane_action.py` 的 forward 分支原来写的是：

```python
world_matrix = camera.matrix_world.copy()      # 缓存矩阵，读到的是「上次求值」的旋转
world_matrix.translation += (...)
camera.matrix_world = world_matrix             # ← 整个 4x4 写回 = loc + rot + scale 全重写
```

`matrix_world` 赋值会把 **rotation 也一起写回去**，而 rotation 正被另一条 60Hz 的姿态消息流写入，
且写回用的是**滞后**的旋转 → 两条流互相覆盖 → 旋转来回跳。

修法：**只写 `location`**（用 `camera.rotation_quaternion` 定方向，它是新鲜值）：

```python
camera.location = camera.location + (camera.rotation_quaternion @ Vector((0.0, 0.0, -distance)))
```

`free_action.py` 的 translation 分支**是同一个 bug，已一并修掉**（带父级时用 `parent_3x3.inverted()` 换算）。

> **经验**：Blender 里做高频增量位移，只写 `location`；绝不要 `matrix_world` 读出来改一点再写回去。

### 4.2 录制性能（**已修**）—— `setting.py::_record_camera_rotation()`

原来的问题：定时器名义 100Hz，每 tick 插 2 次关键帧（`rotation_quaternion` 4 条 + `location` 3 条曲线），
而时间轴只按**场景帧率**（默认 24fps）前进 → **同一帧被重复插 3~4 次**，纯浪费 + 反复触碰 F-Curve。

修法：**帧号守卫**（`_last_frame`），同一帧只插一次。

实测（模拟 100Hz 定时器跑 3 秒 / 24fps 时间轴）：
```
旧行为：keyframe_insert 调用 600 次
新行为：150 次   → 降到 1/4
```

### 4.3 输出帧率同步（**已实现**）

`setting.py::_watch_state()`（每 0.1s）检测 `scene.render.fps / fps_base`，
在「新客户端接入 / 帧率变化」时推 `{"type":"setting","name":"output_fps","value":24}`；
`main.gd` 收下写进 `Options["blender/output_fps"]` → `plane_mode` / `free_mode` 据此定发送频率。

### 4.4 日志开关

* `free_action.py`: `VERBOSE_ROTATION_LOG = False`（原来每条第 100 次/秒 print，会拖慢主线程）
* `streamer.py`: `VERBOSE_INBOUND_LOG = False`（原来每条消息 print + 多一次 json.loads，200 条/秒）
* `setting.py`: `_SET_LINEAR_INTERPOLATION = False`（停止录制时把关键帧改成 LINEAR 的开关）

### 4.5 录制相关的三个"帧率"（**极易混淆**）

| 名称 | 在哪 | 影响 |
|---|---|---|
| **`scene.render.fps`** | Blender 输出属性面板 | ✅ **关键帧的时间分辨率**（录制质量）|
| `scene.blecaco.fps` | 插件面板（默认 10） | ❌ 只管**手机预览流**的推流帧率 |
| 手机发送频率 | `plane_mode.gd` | 数据供给率，自动 = `clamp(output_fps,60,120)` |

### 4.6 插件改完必须重载

`handler.py` 用 `importlib.import_module` 读的是 `sys.modules` **缓存**，
且 `__init__.py::unregister()` **没有清自己的子模块** → **必须重启 Blender**，或控制台：

```python
import sys, importlib
for name in ("blecaco.plane_action", "blecaco.free_action", "blecaco.setting", "blecaco.streamer"):
    mod = sys.modules.get(name)
    if mod: importlib.reload(mod)
```

---

## 5. 待办（按优先级）

| # | 事项 | 位置 | 状态 |
|---|---|---|---|
| 1 | **录制后曲线平滑**（含四元数符号对齐 + 归一化，默认关闭） | `setting.py` | 未做（你说"处理完这个再处理 setting.py"） |
| 2 | **掉帧诊断**：录制时统计 `frame_current` 是否跳帧、实际播放帧率 | `setting.py` | 未做 |
| 3 | **位移改成按真实 `dt` 计算**（现在手机掉帧时实际速度会变慢） | `plane_mode.gd` | 未做，改动约 3 行 |
| 4 | **输出帧率改 60**：记得把 `frame_end` 按比例放大（默认 250 帧在 60fps 下只有 4.2 秒） | Blender 设置 | 未做（零代码） |
| 5 | **开运动模糊**（Blender 输出属性 → Motion Blur，快门 0.5） | Blender 设置 | 未做（零代码，对"顿"的改善最大） |
| 6 | **设置页面**：`record/smoothness` 滑条、速度档位、`plane/plane_speed` | 新页面 | 未做 |
| 7 | 其他 5 个模式（car/game/drone/camera）在 Blender 端**没有对应模块** | `handler.py` ACTION_MODULES | 未做 |
| 8 | `plane_mode.tscn` 的 `ForwardShape` 已是纯占位节点，可删 | 场景 | 可选 |
| 9 | 速度档位数值最终确认（现在 `-4/-2/1/3/9`） | `plane_forward_area.gd` | 待你确认 |

---

## 6. 验证方法 / 工具链（**明天能省很多时间**）

### 6.1 Godot 侧

* 语法检查：`godot --headless --check-only --script res://path.gd`
  ⚠️ **对引用了 autoload（如 `Options`）的脚本会误报 `Identifier not found: Options`** ——
  这是 check-only 不注册 autoload 导致的假报警（用工程里本来正常的 `setting.gd` 对照可复现）。
  **判断脚本是否真的有问题，看「加载场景」有没有报错更可靠：**
  `godot --headless --quit-after 3 res://scenes/modes/plane_mode.tscn`
* 写临时测试脚本时注意：**`--script` 模式下 autoload 不可用**（编译早于注册），
  要改成 `get_root().get_node_or_null("Options")` 动态取
* 新增 `class_name` 后 CLI 需要重建缓存：`godot --headless --import`

### 6.2 这台机器的能力（很有用）

```
DISPLAY=:0 + /dev/dri 可用
→ 可以用真实 GPU 离屏渲染 + 像素读回来验证 shader！
  godot --rendering-driver opengl3 --script res://test.gd
  （SubViewport + get_texture().get_image().get_pixel()）
  今天靠它验证了：光晕圆的渐变公式、遮罩裁剪、颜色分段、方向翻转
```

### 6.3 Blender 侧（无 GUI 也能验）

用「伪造 `bpy` + 伪造包」把 `setting.py` / `plane_action.py` 当模块加载，
纯 Python 就能验证逻辑并量化（今天靠它验证了关键帧写入次数 600→150、输出帧率同步）。

### 6.4 临时文件约定

**测试脚本用完必须删干净**（含 `.godot` 生成的同名 `.uid`）。今天所有临时脚本都已清理，
工程里不应残留 `*_check.gd` / `*_test.gd`。

---

## 7. 踩过的坑（避免重复）

| 坑 | 结论 |
|---|---|
| **`.tscn` 里的 `shader_parameter/xxx` 会覆盖 shader 文件的默认值** | 在检查器里动过材质参数后，编辑器会把值写进 `.tscn`，从此改 shader 文件**不生效**。已把参数全部移到脚本 `@export` |
| `Control` 没有 `to_local()` | 那是 `Node2D` 的方法；用 `active_position - global_position` |
| **Godot shader 里 `#` 不是注释** | 会被当预处理指令报错，只能用 `//` 或 `/* */` |
| `smoothstep` 的 `edge0 == edge1` 是未定义行为 | `gradient_start = 1` 时要 `min(..., 0.999)` |
| `Button` 的 `toggle_mode` 用 `toggled` 不是 `pressed` | — |
| `Image.get_pixel()` 只接受 `int, int` | 不能传 `Vector2` |
| heredoc 写 GDScript 会丢制表符 | 用编辑器工具写 `.gd`，别用 `cat <<EOF` |
| 文件末尾缺换行会让编辑器匹配失败 | 必要时用 Python 做替换 |
