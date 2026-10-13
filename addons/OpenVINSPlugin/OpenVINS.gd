class_name OpenVINS
extends Node
# OpenVINS 运行时封装（单目相机 + IMU 的 VIO，输出带真实尺度的位姿）。
#
# 组成：
#   - AAR: addons/OpenVINSPlugin/bin/<build_type>/OpenVINSPlugin-*.aar
#         Java 入口 com.blecaco.openvins.OpenVINSBridge（静态方法）
#   - IMU：由 AAR 内部的 SensorManager 采集（加速度计 + 陀螺仪，BOOTTIME 时间戳）
#   - 相机帧：由外部（NativeCameraPlugin）通过 feed_frame() 投递
#
# 典型用法（在 free_mode 里）：
#   var vio := OpenVINS.new()
#   add_child(vio)
#   vio.estimator_config_path = "<安卓绝对路径>/estimator_config.yaml"
#   vio.start()
#   camera.frame_available.connect(vio.feed_frame)
#   vio.pose_updated.connect(_on_vio_pose)
#
# 注意：
#   1) 分辨率必须与 kalibr_imucam_chain.yaml 的 resolution 一致（样板 640x480）
#   2) 帧必须为灰度且 buffer.size() == width * height
#   3) VIO 模式下不要用 auto_upright：相机会随手机姿态旋转，
#      会让相机↔IMU 外参不再恒定，应使用固定 frame_rotation

signal vio_initialized
signal pose_updated(a_pose: VioPose)
signal error_raised(a_message: String)

const BRIDGE_CLASS: String = "com.blecaco.openvins.OpenVINSBridge"
const CONTEXT_CLASS: String = "com.blecaco.util.AndroidContext"
const SYSTEM_CLOCK_CLASS: String = "android.os.SystemClock"

## 内置标定配置（随 addon 打包）
const CONFIG_DIR_RES: String = "res://addons/OpenVINSPlugin/config"
const CONFIG_DIR_USER: String = "user://openvins"

const CONFIG_FILES: Array[String] = [
	"estimator_config.yaml",
	"kalibr_imu_chain.yaml",
	"kalibr_imucam_chain.yaml"
]

## estimator_config.yaml 的 Android 绝对路径。
## 留空则自动把内置配置复制到 user:// 后使用（推荐，免 adb push）。
@export var estimator_config_path: String = ""

## 轮询位姿的间隔（秒）；0 表示每帧都取。
@export var poll_interval: float = 0.0

## 状态心跳间隔（秒）；0 = 关闭。用于排查 VIO 是否真的在跑。
@export var status_interval: float = 1.0

var _bridge = null
var _system_clock = null
var _bridge_ready: bool = false
var _running: bool = false
var _initialized_emitted: bool = false
var _poll_timer: float = 0.0

# 诊断计数
var _status_timer: float = 0.0
var _pose_count: int = 0
var _frames_ok: int = 0
var _frames_bad: int = 0


func _ready() -> void:
	if not OS.has_feature("android"):
		return

	_bridge = JavaClassWrapper.wrap(BRIDGE_CLASS)

	if _bridge == null:
		error_raised.emit("无法加载 " + BRIDGE_CLASS)
		return

	_bridge_ready = true


func _process(a_delta: float) -> void:
	if status_interval > 0.0:
		_status_timer += a_delta

		if _status_timer >= status_interval:
			_status_timer = 0.0
			_print_status()

	if not _running or not _bridge_ready:
		return

	if not _initialized_emitted and is_initialized():
		_initialized_emitted = true
		print("[OpenVINS] VIO 初始化完成")
		vio_initialized.emit()

	_poll_timer += a_delta

	if poll_interval > 0.0 and _poll_timer < poll_interval:
		return

	_poll_timer = 0.0

	var pose: VioPose = get_pose()

	if pose != null:
		_pose_count += 1
		pose_updated.emit(pose)


func _print_status() -> void:
	print(
		"[VIO] bridge_ready=%s running=%s init=%s frames_ok=%d frames_bad=%d poses=%d last=%s"
		% [
			_bridge_ready,
			is_running(),
			is_initialized(),
			_frames_ok,
			_frames_bad,
			_pose_count,
			str(get_pose())
		]
	)


func _exit_tree() -> void:
	stop()


# ============================================================
# 生命周期
# ============================================================

func start(a_config_path: String = "") -> bool:
	if not _bridge_ready:
		error_raised.emit("桥接层未就绪，无法启动")
		return false

	if _running:
		return true

	var config_path := a_config_path

	if config_path.is_empty():
		config_path = _prepare_config()

	if config_path.is_empty():
		error_raised.emit("没有可用的 estimator_config.yaml")
		return false

	# 首选：Context 由 Java 侧自行反射解析，避免跨语言传 Java 对象
	# （JavaClassWrapper 对 Java 对象参数的编组会让调用被静默丢弃）。
	_bridge.startWithConfig(config_path)

	# 不信任 startWithConfig 的返回值：实测其布尔返回值可能编组失败而返回
	# null（得到 false），但 Java 侧其实已经启动成功。用 isRunning() 复核。
	var ok: bool = is_running()

	if not ok:
		# 兜底：老版 AAR 没有 startWithConfig，退回传 Context 的旧接口。
		var context = _resolve_context()

		if context != null:
			_bridge.start(context, config_path)

		ok = is_running()

	if not ok:
		error_raised.emit("原生启动失败：" + config_path)
		return false

	_running = true
	_initialized_emitted = false
	print("[OpenVINS] 已启动：", config_path)
	return true


func stop() -> void:
	if not _bridge_ready or not _running:
		return

	_bridge.stop()
	_running = false
	print("[OpenVINS] 已停止")


func is_running() -> bool:
	if not _bridge_ready:
		return false

	return bool(_bridge.isRunning())


func is_initialized() -> bool:
	if not _bridge_ready or not _running:
		return false

	return bool(_bridge.isInitialized())


# ============================================================
# 相机帧
# ============================================================

## 可直接接 NativeCamera.frame_available。
func feed_frame(a_info: FrameInfo) -> void:
	if not _running or not _bridge_ready:
		return

	if not a_info.is_grayscale():
		return

	var width := a_info.get_width()
	var height := a_info.get_height()
	var buffer := a_info.get_buffer()

	if width <= 0 or height <= 0:
		_frames_bad += 1
		return

	if buffer.size() != width * height:
		_frames_bad += 1

		if _frames_bad <= 3:
			push_warning(
				"[OpenVINS] 帧尺寸与 buffer 不匹配，已丢弃"
			)

		return

	_frames_ok += 1
	_bridge.feedGray(buffer, width, height, _now_seconds())


# ============================================================
# 位姿
# ============================================================

func get_pose() -> VioPose:
	if not _running or not _bridge_ready:
		return null

	return VioPose.from_java_pose(_bridge.getPose())


func get_trajectory() -> PackedFloat64Array:
	if not _bridge_ready:
		return PackedFloat64Array()

	var raw = _bridge.getTrajectory()

	if typeof(raw) == TYPE_PACKED_FLOAT64_ARRAY:
		return raw

	return PackedFloat64Array()


# ============================================================
# 内部
# ============================================================

## 返回 estimator_config.yaml 的 Android 绝对路径。
##   1) 外部显式指定了 estimator_config_path 就直接用；
##   2) 否则把内置的三份配置复制到 user://openvins/ 再返回其绝对路径
##      （OpenVINS 需要绝对路径，而 res:// 打包后不可直接读取）。
func _prepare_config() -> String:
	if not estimator_config_path.is_empty():
		return estimator_config_path

	DirAccess.make_dir_recursive_absolute(CONFIG_DIR_USER)

	for file_name in CONFIG_FILES:
		var source_path := CONFIG_DIR_RES + "/" + file_name
		var bytes := FileAccess.get_file_as_bytes(source_path)

		if bytes.is_empty():
			error_raised.emit("缺少内置配置：" + source_path)
			return ""

		var target_path := CONFIG_DIR_USER + "/" + file_name
		var file := FileAccess.open(target_path, FileAccess.WRITE)

		if file == null:
			error_raised.emit("无法写入配置：" + target_path)
			return ""

		file.store_buffer(bytes)
		file.close()

	var absolute_path := ProjectSettings.globalize_path(
		CONFIG_DIR_USER + "/estimator_config.yaml"
	)

	print("[OpenVINS] 使用内置配置：", absolute_path)
	return absolute_path


func _resolve_context():
	var helper = JavaClassWrapper.wrap(CONTEXT_CLASS)

	if helper == null:
		push_error("[OpenVINS] 找不到 " + CONTEXT_CLASS)
		return null

	return helper.getContext()


## 返回 BOOTTIME 秒，与 AAR 内 IMU 的时间戳同基准。
func _now_seconds() -> float:
	if _system_clock == null:
		_system_clock = JavaClassWrapper.wrap(SYSTEM_CLOCK_CLASS)

	if _system_clock != null:
		return float(_system_clock.elapsedRealtimeNanos()) * 1e-9

	# 退化方案：非 BOOTTIME，仅用于跑通流程
	return float(Time.get_ticks_usec()) * 1e-6
