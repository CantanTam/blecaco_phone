extends Node

const INITIALIZE_RETRY_INTERVAL: float = 0.25

# 发送频率自适应 Blender 的输出帧率（插件推送 → main.gd 收下 → Options）。
# 规则同 plane_mode.gd：不低于 MIN（实时手感），不高于 MAX（别刷爆）。
const MIN_SEND_RATE: float = 60.0
const MAX_SEND_RATE: float = 120.0

# 打开后会以 ~100Hz 打印每条四元数，会把 logcat 环形缓冲区冲掉，
# 导致真正有用的日志在你回看时已经消失；排查时再改 true。
const VERBOSE_ORIENTATION_LOG := false

var rotation_sender = preload(
	"res://scripts/getrotation.gd"
).new()

var rotation_send_timer: float = 0.0
var initialize_retry_timer: float = 0.0

var connection_node: Node = null

# 手机是否已经完成初始姿态校准
var phone_calibrated: bool = false

# Blender 是否已经记录摄像机初始姿态
var free_mode_initialized: bool = false


# ============================================================
# 位姿来源：光流（默认） / OpenVINS —— 手动切换
# ============================================================
# 2026-10-17 接入说明：
#  - 两套都只负责「平移」这一路；姿态仍由上面的 getrotation.gd 发四元数，行为完全不变。
#  - 默认 POSE_SOURCE_FLOW → 不动任何既有行为；只有手动切到 OpenVINS 才启动 VIO 插件。
#  - 切过去前会先停掉光流的 NativeCamera（Android 同一时刻只允许一个相机客户端持有摄像头）。
#  - OpenVINS 输出是**米**（机体系下的相对位移），所以协议里带 "unit": "meter"；
#    Blender 的 free_action.py 按 unit 选比例，缺省 "pixel" 时就是原来的光流路径。
# 随 APK 分发的【通用配置】（res://config/，由 export include_filter 打包）。
# 手机外部私有目录里若已有同名文件则**不覆盖**（现场调参优先）。
const BUNDLED_CONFIG_FILES := [
	"estimator_config.yaml",
	"kalibr_imu_chain.yaml",
	"kalibr_imucam_chain.yaml",
]

const POSE_SOURCE_FLOW := "flow"
const POSE_SOURCE_OPENVINS := "openvins"

# 切到 OpenVINS 时，光流的相机（NativeCameraPlugin）放开摄像头可能要几十~几百毫秒，
# 太早去开插件里的 Camera2 会失败 —— 所以失败后重试几次再决定退回光流。
const OPENVINS_START_RETRIES := 4
const OPENVINS_RETRY_GAP_SEC := 0.5

# 位移死区（米）。⚠️ Blender 端是**累加**语义（camera.location += 每帧位移，
# 光流那条路发的就是帧间增量），所以这里也必须发"帧间增量"，不能发"相对原点的绝对偏移"，
# 否则手机静止时也会被一遍遍累加、数值直接爆炸。
# 小于死区的位移会**攒着**（_ov_pending），够了一次性发出去，所以不会丢慢速移动。
const OPENVINS_MIN_STEP_M := 0.002

# 单次跳变上限（米）。VIO 跟丢/重新初始化时位姿会瞬间重置，若照发就会让 Blender 里"瞬移"。
# 超过这个值就认为发生了重置：丢弃本次并清空攒批（20~50Hz 下 0.5m/帧 ≈ 10~25 m/s，正常手持到不了）。
const OPENVINS_MAX_STEP_M := 0.5

# ── VIO 安全重启（unlink→link 时要求"重新校准初始化"）──
# 为什么不能同帧 stop+start：插件 stop() 是**异步**关 Camera2 设备，
# 立刻 start() 会撞上没释放的相机 → onError → 之后再也收不到帧（曾经踩过这个坑）。
const OPENVINS_RESTART_RELEASE_SEC := 1.0    # 先等相机真正释放
const OPENVINS_RESTART_VERIFY_SEC := 4.0     # 等"帧恢复"的上限
const OPENVINS_RESTART_MAX_TRIES := 3

# 位姿来源切换的冷却时间（秒）。
# ⚠️ 必须要有：第三方 NativeCameraPlugin 在相机被快速反复开关时，
# 它的 onConfigured 会对已置空的 CameraDevice 调 createCaptureRequest →
# NullPointerException（CameraCaptureThread）→ 整个 App 崩掉。
# 冷却期内忽略点击，保证相机交接是"单飞"的。
const POSE_SWITCH_COOLDOWN_SEC := 2.0

@onready var optical_flow: Node = $OpticalFlowController
@onready var openvins: Node = $OpenVINS
@onready var pose_source_button: Button = $PoseSourceButton

# 同一个按钮用两个 icon 表示两种状态（把你的图标放到这两个路径即可，或改这里的路径）
const ICON_FLOW_PATH := "res://resources/OpticalFlow.svg"
const ICON_VIO_PATH := "res://resources/OpenVINS.svg"
var _tex_flow: Texture2D = null
var _tex_vio: Texture2D = null

# ── 两个按钮的颜色状态（统一 50% 半透明）──
const BTN_COLOR_WHITE := Color(0.0, 0.0, 0.0, 0.5)       # 常规：半透明白
const BTN_COLOR_PREPARING := Color(1.0, 1.0, 0.0, 0.5)   # #ffff00 · 初始化校正尚未完成
const BTN_COLOR_READY := Color(0.0, 1.0, 0.0, 0.5)       # #00ff00 · 初始化校正完成
const BTN_READY_GREEN_SEC := 3.0                         # 绿色保持时长（秒）

var pose_source: String = POSE_SOURCE_FLOW

# 上一帧位姿（算帧间增量用）与攒批缓冲
var _ov_last_pos: Vector3 = Vector3.ZERO
var _ov_has_last: bool = false
var _ov_pending: Vector3 = Vector3.ZERO

var _btn_style: StyleBoxFlat = null
var _vio_green_timer: float = -1.0   # >0 表示绿色倒计时中
enum OvRestart { NONE, WAIT_RELEASE, VERIFY }
var _switch_cooldown: float = 0.0

# 触摸设备上 Godot 会把触摸同时模拟成鼠标事件 → 只处理其中一种，
# 否则一次点击会触发两次切换（drone_mode 就这么踩过坑）。
var _touch_platform: bool = false

var _ov_restart_state: int = OvRestart.NONE
var _ov_restart_timer: float = 0.0
var _ov_restart_tries: int = 0
var _ov_frames_mark: int = 0

var _ov_retries_left: int = 0
var _ov_retry_timer: float = 0.0
var _ov_ready: bool = false


# 当前发送频率（Hz）：跟着 Blender 的输出帧率走
func _send_rate() -> float:
	return clampf(
		Options.get_float("blender/output_fps"),
		MIN_SEND_RATE,
		MAX_SEND_RATE
	)


## addon_set 的全局移动倍数（Options: move_speed，默认 1.0）。
## Free 只缩放平移（光流/OpenVINS），不缩放旋转。
func _move_scale() -> float:
	return maxf(0.0, Options.get_float("move_speed"))


func _ready() -> void:
	_touch_platform = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
	)

	# 查找现有的 Connection 节点
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	if rotation_sender.is_available():
		print("[Orientation] Plugin loaded")
	else:
		push_error(
			"[Orientation] Plugin singleton not found"
		)

	if connection_node == null:
		push_error(
			"[Orientation] Connection node not found"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
			"[Orientation] Connection.send_action() not found"
		)

	# 两个按钮分别代表两种位姿来源，共用同一位置（同一时刻只显示一个）
	# 单按钮 + 双 icon：点一下 = 在"光流 / VIO"之间切换
	# ⚠️ 不连 button.pressed：实测该区域在 GUI 阶段被上层控件吃掉（触摸到了、按钮收不到），
	#    改由 _input() 做矩形命中检测（_input 一定先于 GUI 收到），见 _input()。
	if pose_source_button != null:
		pose_source_button.focus_mode = Control.FOCUS_NONE
		_btn_style = _dup_button_style(pose_source_button)

	# 载入两个状态图标（缺失时退化为文字，不会崩）
	if ResourceLoader.exists(ICON_FLOW_PATH):
		_tex_flow = load(ICON_FLOW_PATH)
	if ResourceLoader.exists(ICON_VIO_PATH):
		_tex_vio = load(ICON_VIO_PATH)
	if _tex_flow == null or _tex_vio == null:
		push_warning("[OpenVINS] 状态图标缺失，改用文字显示（可放到 %s / %s）" % [ICON_FLOW_PATH, ICON_VIO_PATH])

	if connection_node != null and connection_node.has_signal("action_sending_changed"):
		# LinkButton 恢复发送时：把手机"当前姿态"当成新的零点重新校准，
		# 配合 Blender 侧 relink 恢复的相机基准 → 扫描完换空间时相机不会跳。
		connection_node.connect(
			"action_sending_changed",
			_on_action_sending_changed
		)

	# 尽早把 APK 内置的通用配置释放到手机（幂等；已有则跳过）
	_ensure_bundled_config()



	_apply_pose_source()

	# ── 临时诊断：确认按钮在屏幕上的真实位置 vs 视口大小 ──
	if pose_source_button != null:
		print(
			"[DBG] PoseSourceButton global_rect=%s  viewport=%s"
			% [
				str(pose_source_button.get_global_rect()),
				str(get_viewport().get_visible_rect().size)
			]
		)


func _process(delta: float) -> void:
	if _switch_cooldown > 0.0:
		_switch_cooldown = maxf(_switch_cooldown - delta, 0.0)

	if not rotation_sender.has_orientation_data():
		return

	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	# 第一次进入 Free Mode 时，记录手机当前姿态
	if not phone_calibrated:
		if not rotation_sender.calibrate():
			return

		phone_calibrated = true

		print("[Orientation] Phone orientation calibrated")

	# 先通知 Blender 保存活动摄像机的初始旋转
	# 初始化消息成功发送前，不发送手机旋转数据
	if not free_mode_initialized:
		initialize_retry_timer += delta

		if initialize_retry_timer < INITIALIZE_RETRY_INTERVAL:
			return

		initialize_retry_timer = 0.0

		var sent: bool = bool(
			connection_node.call(
				"send_action",
				"free",
				{"command": "initialize"}
			)
		)

		if sent:
			free_mode_initialized = true

			print(
				"[Orientation] Blender camera initialized"
			)

		return

	# 初始化完成后，继续以约 100 Hz 发送手机相对旋转
	rotation_send_timer += delta

	if rotation_send_timer < 1.0 / _send_rate():
		return

	rotation_send_timer = 0.0

	var q: Quaternion = (
		rotation_sender.get_rotation_quaternion()
	)

	var quaternion_data: Dictionary = {
		"x": q.x,
		"y": q.y,
		"z": q.z,
		"w": q.w
	}

	connection_node.call(
		"send_action",
		"free",
		quaternion_data
	)

	# OpenVINS 模式下，平移由 VIO 提供（光流控制器此时已被停掉）
	if pose_source == POSE_SOURCE_OPENVINS:
		# 绿色 3 秒 → 转半透明白
		if _vio_green_timer > 0.0:
			_vio_green_timer -= delta
			if _vio_green_timer <= 0.0:
				_vio_green_timer = -1.0
				_set_vio_button_color(BTN_COLOR_WHITE)

		# 正在安全重启：推进状态机，重启期间不发任何位移（避免用到过期位姿）
		if _ov_restart_state != OvRestart.NONE:
			_update_vio_restart(delta)
			return
		if _ov_retries_left > 0 and not openvins.is_running():
			_ov_retry_timer += delta
			if _ov_retry_timer >= OPENVINS_RETRY_GAP_SEC:
				_ov_retry_timer = 0.0
				_ov_retries_left -= 1
				_ensure_bundled_config()
				if openvins.start("", ""):
					print("[OpenVINS] 重试成功")
				elif _ov_retries_left <= 0:
					push_warning(
						"[OpenVINS] 重试 %d 次仍失败，退回光流：%s"
						% [
							OPENVINS_START_RETRIES,
							openvins.get_last_error()
						]
					)
					pose_source = POSE_SOURCE_FLOW
					_apply_pose_source()
					return
		else:
			_send_openvins_translation()

	if VERBOSE_ORIENTATION_LOG:
		print(
			"[Orientation] Quaternion sent: ",
			"X=", snappedf(q.x, 0.01),
			" Y=", snappedf(q.y, 0.01),
			" Z=", snappedf(q.z, 0.01),
			" W=", snappedf(q.w, 0.01)
		)


# ============================================================
# 位姿来源切换（光流 ⇄ OpenVINS）
# ============================================================

## 点按钮 → 在两种位姿来源之间切换
func _on_pose_button_pressed() -> void:
	print("[OpenVINS] 按钮被点击，当前来源=", pose_source)
	_on_pose_source_toggled(pose_source != POSE_SOURCE_OPENVINS)


func _on_pose_source_toggled(pressed: bool) -> void:
	# 切换后进入冷却：期间的点击直接忽略（避免相机被快速反复开关 → 第三方插件 NPE 崩溃）
	_switch_cooldown = POSE_SWITCH_COOLDOWN_SEC

	pose_source = (
		POSE_SOURCE_OPENVINS if pressed else POSE_SOURCE_FLOW
	)
	_apply_pose_source()


func _apply_pose_source() -> void:
	var use_openvins := pose_source == POSE_SOURCE_OPENVINS

	# 同一个按钮：换 icon + 换颜色
	if pose_source_button != null:
		if _tex_flow != null and _tex_vio != null:
			pose_source_button.icon = _tex_vio if use_openvins else _tex_flow
			pose_source_button.text = ""
		else:
			pose_source_button.text = "VIO" if use_openvins else "光流"

	_vio_green_timer = -1.0
	_set_vio_button_color(BTN_COLOR_PREPARING if use_openvins else BTN_COLOR_WHITE)

	if use_openvins:
		# ① 先让出摄像头：停光流相机 + 停它的发送
		if optical_flow != null:
			optical_flow.set_process(false)
			var flow_camera: Node = optical_flow.get_node_or_null("NativeCamera")
			if flow_camera != null and flow_camera.has_method("stop"):
				flow_camera.call("stop")

		# ② 启动 VIO（相机 + Android IMU 都在插件内部）
		if openvins == null or not openvins.is_available():
			push_warning("[OpenVINS] 插件不可用，保持光流")
			pose_source = POSE_SOURCE_FLOW
			_apply_pose_source()
			return

		openvins.request_camera_permission()
		_ov_restart_state = OvRestart.NONE
		_ov_restart_timer = 0.0
		_ov_has_last = false
		_ov_pending = Vector3.ZERO
		_ov_ready = false
		_ov_retries_left = OPENVINS_START_RETRIES
		_ov_retry_timer = 0.0

		_ensure_bundled_config()

		if not openvins.start("", ""):
			# 不立刻放弃：相机的让出是异步的，留给 _process 重试
			print(
				"[OpenVINS] 首次启动失败（%s），%.1fs 后重试（最多 %d 次）"
				% [
					openvins.get_last_error(),
					OPENVINS_RETRY_GAP_SEC,
					OPENVINS_START_RETRIES
				]
			)
			_set_vio_button_color(BTN_COLOR_PREPARING)
			return

		print("[OpenVINS] 已切到位姿来源：OpenVINS")
	else:
		# 切回光流：停掉 VIO（省电 + 让出摄像头）
		_ov_retries_left = 0
		_ov_ready = false
		_ov_restart_state = OvRestart.NONE
		_ov_restart_timer = 0.0
		_ov_has_last = false
		_ov_pending = Vector3.ZERO
		_vio_green_timer = -1.0
		if openvins != null and openvins.is_available():
			openvins.stop()

		if optical_flow != null:
			optical_flow.set_process(true)
			# 复用光流控制器自己的相机启动流程
			if optical_flow.has_method("_start_camera"):
				optical_flow.call("_start_camera")

		print("[OpenVINS] 已切回位姿来源：光流")


func _send_openvins_translation() -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		return
	if not connection_node.has_method("send_action"):
		return

	var pose: Array = openvins.get_pose()
	if pose.size() != 7:
		return   # VIO 还没给出有效位姿（初始化中）

	# native 侧给的是**相机位姿**：
	#   position = p_CinG（相机在世界系的位置）
	#   quaternion = 相机姿态，数组顺序 [qw,qx,qy,qz]（见 native-lib.cpp:899）
	var q := Quaternion(pose[4], pose[5], pose[6], pose[3])   # x,y,z,w
	var p := Vector3(pose[0], pose[1], pose[2])

	if not _ov_ready:
		_ov_ready = true
		# 初始化校正完成：先绿 3 秒，然后转半透明白
		_set_vio_button_color(BTN_COLOR_READY)
		_vio_green_timer = BTN_READY_GREEN_SEC
		print("[OpenVINS] VIO 初始化校正完成（按钮先绿 %.0f 秒）" % BTN_READY_GREEN_SEC)

	var step_cam := _openvins_step(p, q)
	if step_cam == Vector3.ZERO:
		return   # 没动（或在死区内攒着）

	# 全局移动倍数只乘平移（米），不乘旋转
	step_cam = step_cam * _move_scale()

	connection_node.call("send_action", "free", {
		"command": "translation",
		"unit": "meter",
		"x": step_cam.x,
		"y": step_cam.y,
		"z": step_cam.z
	})


## 把"当前相机位姿"换算成要发给 Blender 的**机体系帧间增量（米）**。
## 抽成独立函数是为了能脱离设备单测（见 check_openvins_step_tmp.gd）。
## 返回 Vector3.ZERO = 本次不发。
func _openvins_step(p: Vector3, q: Quaternion) -> Vector3:
	if not _ov_has_last:
		# 第一帧只记基准，不发（避免切换瞬间的跳变）
		_ov_last_pos = p
		_ov_has_last = true
		return Vector3.ZERO

	var delta_world := p - _ov_last_pos
	_ov_last_pos = p

	if delta_world.length() > OPENVINS_MAX_STEP_M:
		# VIO 重置/突变：不发、清空攒批，避免 Blender 里瞬移
		_ov_pending = Vector3.ZERO
		push_warning(
			"[OpenVINS] 位姿跳变 %.3f m（>%.1f m），按重置处理并重新基准"
			% [delta_world.length(), OPENVINS_MAX_STEP_M]
		)
		return Vector3.ZERO

	_ov_pending += delta_world

	if _ov_pending.length() < OPENVINS_MIN_STEP_M:
		return Vector3.ZERO   # 攒着，下次一起发

	var step_world := _ov_pending
	_ov_pending = Vector3.ZERO

	# 世界系增量 → 相机（机）体系：与光流那条路发的"图像/手机系位移"语义对齐，
	# Blender 再用相机自身旋转把 local 位移转成 world 位移（见 free_action.py 2.4）。
	# 注：native 把 OpenVINS 的 JPL 四元数只做了分量重排 → 拿到的 Hamilton 四元数
	#     实际表示"相机→世界"，所以这里要取 inverse() 才是"世界→相机"。
	return q.inverse() * step_world


## 设置 VIO 按钮背景色（只改 duplicated StyleBoxFlat 的 bg_color）
func _set_vio_button_color(color: Color) -> void:
	if _btn_style != null:
		_btn_style.bg_color = color


## 复制按钮样式，让四个状态共用一个 StyleBoxFlat，方便运行时按状态改颜色
func _dup_button_style(btn: Button) -> StyleBoxFlat:
	var base := btn.get_theme_stylebox("normal")
	if not (base is StyleBoxFlat):
		return null
	var style := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		btn.add_theme_stylebox_override(state, style)
	return style


## LinkButton 暂停/恢复 action 发送时同步
func _on_action_sending_changed(enabled: bool) -> void:
	if not enabled:
		return   # 暂停：什么都不用做（Blender 那边已收到 unlink 并存好相机旋转）

	# ① 恢复：重新校准手机姿态（当前姿态 = 新零点），之后的旋转相对它输出
	if rotation_sender.calibrate():
		print("[OpenVINS] Link 恢复：已重新校准手机姿态")
	else:
		push_warning("[OpenVINS] Link 恢复：手机姿态重新校准失败（暂无数据？）")

	# ② VIO 也要重新校准初始化（丢弃旧状态）：安全重启
	if pose_source == POSE_SOURCE_OPENVINS:
		_begin_vio_restart()


## 确保手机上有一份配置：没有才从 APK 内置的 res://config/ 复制过去。
## 手机上已存在的文件**一律不覆盖**（现场调参优先）；但若内容明显损坏（首行不是 %YAML:）
## 就用内置版本覆盖 —— OpenCV 的 FileStorage 遇到非法 yaml 会抛异常并让整进程 abort。
func _ensure_bundled_config() -> void:
	if openvins == null or not openvins.is_available():
		return

	# openvins 是 GDScript 包装节点，对外方法是 external_files_dir()
	if not openvins.has_method("external_files_dir"):
		push_warning("[OpenVINS] 包装层缺少 external_files_dir()，跳过内置配置释放")
		return

	var root: String = str(openvins.call("external_files_dir"))
	if root.is_empty():
		push_warning("[OpenVINS] 拿不到外部私有目录，跳过内置配置释放")
		return

	var dir_path: String = root + "/config"
	DirAccess.make_dir_recursive_absolute(dir_path)

	for file_name in BUNDLED_CONFIG_FILES:
		var dst: String = dir_path + "/" + file_name
		var src: String = "res://config/" + file_name

		if FileAccess.file_exists(dst):
			if _looks_like_opencv_yaml(dst):
				continue   # 手机上已有且看起来合法 → 保留
			push_warning("[OpenVINS] 手机上的配置无效，改用内置版本: " + dst)

		if not FileAccess.file_exists(src):
			push_warning("[OpenVINS] APK 内置配置缺失: " + src)
			continue

		if not _looks_like_opencv_yaml(src):
			push_warning("[OpenVINS] APK 内置配置格式不对（首行应为 %YAML:）: " + src)
			continue

		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src)
		if bytes.is_empty():
			push_warning("[OpenVINS] 内置配置为空: " + src)
			continue

		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			push_warning("[OpenVINS] 无法写入配置: " + dst)
			continue
		f.store_buffer(bytes)
		f.close()
		print("[OpenVINS] 已释放内置配置 → " + dst)


## OpenCV FileStorage 只认首行 %YAML:；用它做最小合法性校验
func _looks_like_opencv_yaml(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var first_line := f.get_line()
	f.close()
	return first_line.strip_edges().begins_with("%YAML:")


# ============================================================
# VIO 安全重启（unlink→link 时要求重新校准初始化）
# ============================================================

## 发起重启：先停、清状态，交给 _process 的状态机"等相机释放 → 启动 → 验证帧"
func _begin_vio_restart() -> void:
	if openvins == null or not openvins.is_available():
		return

	print("[OpenVINS] 重启 VIO：准备重新校准初始化")

	openvins.stop()

	_ov_ready = false
	_ov_has_last = false
	_ov_pending = Vector3.ZERO
	_ov_retries_left = 0
	_ov_restart_tries = 0
	_ov_restart_timer = 0.0
	_ov_restart_state = OvRestart.WAIT_RELEASE
	_vio_green_timer = -1.0
	_set_vio_button_color(BTN_COLOR_PREPARING)   # 黄：重新校准中


## 状态机：WAIT_RELEASE（等相机释放）→ start() → VERIFY（等帧恢复）
func _update_vio_restart(delta: float) -> void:
	_ov_restart_timer += delta

	match _ov_restart_state:
		OvRestart.WAIT_RELEASE:
			if _ov_restart_timer < OPENVINS_RESTART_RELEASE_SEC:
				return
			_ov_restart_timer = 0.0
			_ensure_bundled_config()
			if openvins.start("", ""):
				_ov_frames_mark = int(openvins.call("frame_count"))
				_ov_restart_state = OvRestart.VERIFY
				print("[OpenVINS] 重启已发起，验证帧是否恢复…")
			else:
				_ov_restart_tries += 1
				print(
					"[OpenVINS] 重启失败(%d/%d)：%s"
					% [
						_ov_restart_tries,
						OPENVINS_RESTART_MAX_TRIES,
						openvins.get_last_error()
					]
				)
				if _ov_restart_tries >= OPENVINS_RESTART_MAX_TRIES:
					_give_up_vio_restart()

		OvRestart.VERIFY:
			var now_frames := int(openvins.call("frame_count"))
			if now_frames > _ov_frames_mark:
				_ov_restart_state = OvRestart.NONE
				_ov_restart_timer = 0.0
				_vio_green_timer = -1.0
				_set_vio_button_color(BTN_COLOR_PREPARING)
				print("[OpenVINS] VIO 已重启完成（帧已恢复），等待重新初始化")
			elif _ov_restart_timer >= OPENVINS_RESTART_VERIFY_SEC:
				_ov_restart_timer = 0.0
				_ov_restart_tries += 1
				print(
					"[OpenVINS] 重启后 %.1fs 没收到帧(%d/%d)，再试"
					% [
						OPENVINS_RESTART_VERIFY_SEC,
						_ov_restart_tries,
						OPENVINS_RESTART_MAX_TRIES
					]
				)
				if _ov_restart_tries >= OPENVINS_RESTART_MAX_TRIES:
					_give_up_vio_restart()
				else:
					openvins.stop()
					_ov_restart_state = OvRestart.WAIT_RELEASE


## 多次尝试仍拿不到帧 → 退回光流（不留"看不见的死状态"）
func _give_up_vio_restart() -> void:
	_ov_restart_state = OvRestart.NONE
	_ov_restart_timer = 0.0
	push_warning(
		"[OpenVINS] 重启 %d 次仍拿不到相机帧，退回光流"
		% OPENVINS_RESTART_MAX_TRIES
	)
	pose_source = POSE_SOURCE_FLOW
	_apply_pose_source()


## 触摸命中检测（绕过 GUI 被上层控件拦截的问题）
func _input(event: InputEvent) -> void:
	var pressed := false
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch:
		pressed = event.pressed
		pos = event.position
	elif event is InputEventMouseButton:
		if _touch_platform:
			return
		pressed = event.pressed
		pos = event.position
	if not pressed:
		return

	if pose_source_button == null or not pose_source_button.visible:
		return

	if pose_source_button.get_global_rect().has_point(pos):
		get_viewport().set_input_as_handled()

		if _switch_cooldown > 0.0:
			print(
				"[OpenVINS] 冷却中(剩 %.1fs)，忽略本次点击"
				% _switch_cooldown
			)
			return

		print("[OpenVINS] 命中按钮区域(%s)，当前来源=%s" % [str(pos), pose_source])
		_on_pose_button_pressed()
