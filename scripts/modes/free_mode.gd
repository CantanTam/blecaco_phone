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

@onready var optical_flow: Node = $OpticalFlowController
@onready var openvins: Node = $OpenVINS
@onready var pose_source_button: Button = $PoseSourceButton
@onready var ready_dot: Panel = $PoseSourceButton/ReadyDot

# 就绪指示点颜色：启动中=琥珀，已出位姿=绿
const READY_DOT_STARTING := Color(0.95, 0.65, 0.15, 1.0)
const READY_DOT_READY := Color(0.20, 0.85, 0.35, 1.0)

var pose_source: String = POSE_SOURCE_FLOW

# 上一帧位姿（算帧间增量用）与攒批缓冲
var _ov_last_pos: Vector3 = Vector3.ZERO
var _ov_has_last: bool = false
var _ov_pending: Vector3 = Vector3.ZERO

var _dot_style: StyleBoxFlat = null
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


func _ready() -> void:
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

	# 位姿来源切换按钮（默认光流）
	if pose_source_button != null:
		# toggle 按钮：未按下=光流（白色透明）、按下=OpenVINS（白色不透明）
		pose_source_button.toggled.connect(_on_pose_source_toggled)

	if connection_node != null and connection_node.has_signal("action_sending_changed"):
		# LinkButton 恢复发送时：把手机"当前姿态"当成新的零点重新校准，
		# 配合 Blender 侧 relink 恢复的相机基准 → 扫描完换空间时相机不会跳。
		connection_node.connect(
			"action_sending_changed",
			_on_action_sending_changed
		)

	# 尽早把 APK 内置的通用配置释放到手机（幂等；已有则跳过）
	_ensure_bundled_config()

	if ready_dot != null:
		# 小圆点不拦触摸（同 RecordButton 的 Indicator 写法）
		ready_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var dot_style := ready_dot.get_theme_stylebox("panel")
		if dot_style is StyleBoxFlat:
			_dot_style = dot_style.duplicate() as StyleBoxFlat
			ready_dot.add_theme_stylebox_override("panel", _dot_style)

	_apply_pose_source()


func _process(delta: float) -> void:
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

func _on_pose_source_toggled(pressed: bool) -> void:
	pose_source = (
		POSE_SOURCE_OPENVINS if pressed else POSE_SOURCE_FLOW
	)
	_apply_pose_source()


func _apply_pose_source() -> void:
	var use_openvins := pose_source == POSE_SOURCE_OPENVINS

	if pose_source_button != null:
		# set_pressed_no_signal：避免程序化改状态又触发 toggled 造成递归
		pose_source_button.set_pressed_no_signal(use_openvins)
		# 文字只标"来源"；就绪与否看右下角小圆点
		pose_source_button.text = "VIO" if use_openvins else "光流"

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
			_set_ready_dot(false, true)
			return

		print("[OpenVINS] 已切到位姿来源：OpenVINS")
	else:
		# 切回光流：停掉 VIO（省电 + 让出摄像头）
		_ov_retries_left = 0
		_ov_ready = false
		_ov_has_last = false
		_ov_pending = Vector3.ZERO
		_set_ready_dot(false, false)
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
		_set_ready_dot(true, true)
		print("[OpenVINS] VIO 已给出位姿，切换完成")

	var step_cam := _openvins_step(p, q)
	if step_cam == Vector3.ZERO:
		return   # 没动（或在死区内攒着）

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


## 右下角就绪指示点：visible=false 表示"当前是光流"；否则用颜色表示 VIO 状态
func _set_ready_dot(ready: bool, show: bool) -> void:
	if ready_dot == null:
		return
	ready_dot.visible = show
	if not show:
		return
	if _dot_style != null:
		_dot_style.bg_color = READY_DOT_READY if ready else READY_DOT_STARTING

## LinkButton 暂停/恢复 action 发送时同步
func _on_action_sending_changed(enabled: bool) -> void:
	if not enabled:
		return   # 暂停：什么都不用做（Blender 那边已收到 unlink 并存好相机旋转）

	# 恢复：重新校准手机姿态（当前姿态 = 新零点），之后的旋转相对它输出
	if rotation_sender.calibrate():
		print("[OpenVINS] Link 恢复：已重新校准手机姿态")
	else:
		push_warning("[OpenVINS] Link 恢复：手机姿态重新校准失败（暂无数据？）")


## 确保手机上有一份配置：没有才从 APK 内置的 res://config/ 复制过去。
## 手机上已存在的文件**一律不覆盖** —— 方便现场调参，也避免升级 APK 冲掉调好的参数。
func _ensure_bundled_config() -> void:
	if openvins == null or not openvins.is_available():
		return

	# 注意：openvins 是 GDScript 包装节点（addons/OpenVINSGodot/OpenVINSGodot.gd），
	# 它对外暴露的是 external_files_dir()（内部再去调单例的 getExternalFilesDir()）。
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

		# 手机上已有 → 保留（但做一次"是否像 OpenCV yaml"的最小校验：
		# OpenCV 的 FileStorage 要求第一行是 %YAML:，否则会抛异常并让整进程 abort。
		# 校验不通过就当它损坏，用内置版本覆盖 —— 属于自愈，不会误伤正常配置。
		if FileAccess.file_exists(dst):
			if _looks_like_opencv_yaml(dst):
				continue
			push_warning("[OpenVINS] 手机上的配置无效，改用内置版本: " + dst)

		if not FileAccess.file_exists(src):
			push_warning("[OpenVINS] APK 内置配置缺失: " + src)
			continue

		# 内置文件自身也要合法，否则不复制（避免把坏的铺到手机上）
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
	# GDScript 的 lstrip() 需要参数，用 strip_edges() 更省事
	return first_line.strip_edges().begins_with("%YAML:")
