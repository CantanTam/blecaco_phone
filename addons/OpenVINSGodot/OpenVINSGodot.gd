extends Node

# ============================================================
# OpenVINS 的 GDScript 侧包装（可直接搬到 mobile 项目里用）
#
# 原生单例 "OpenVINS" 提供：
#   start(privateRoot, recordDir) / stop() / isRunning()
#   getPose() -> double[7] = [x,y,z, qw,qx,qy,qz]（空数组 = 还没有位姿）
#   getTrajectory() -> double[7*n]
#   poll()  → 触发 "pose" 信号（每帧调一次即可）
#   getStats() / getLastError() / getExternalFilesDir() / setRecording(bool)
#
# ⚠️ 相机与 IMU 都由原生侧负责（IMU 用 Android SensorManager，
#    与相机 Image.timestamp 同钟域）；Godot 只负责显示与业务逻辑。
# ============================================================

signal pose_changed(pose: Dictionary)
signal status_changed(message: String)

const PLUGIN_SINGLETON_NAME := "OpenVINS"
const CAMERA_PERMISSION := "android.permission.CAMERA"

var _ov: Object = null
var _started := false
var pose_count := 0


func _ready() -> void:
	if not Engine.has_singleton(PLUGIN_SINGLETON_NAME):
		push_warning("[OpenVINS] 本平台没有 OpenVINS 插件（单例不存在）")
		return

	_ov = Engine.get_singleton(PLUGIN_SINGLETON_NAME)
	_ov.connect("pose", _on_native_pose)
	_ov.connect("status", _on_native_status)
	print("[OpenVINS] 插件已就绪")


func is_available() -> bool:
	return _ov != null


## App 的外部私有目录（配置放 <这里>/config/estimator_config.yaml）
func external_files_dir() -> String:
	if _ov == null:
		return ""
	return str(_ov.getExternalFilesDir())


func has_camera_permission() -> bool:
	if not OS.has_feature("android"):
		return true
	return OS.get_granted_permissions().has(CAMERA_PERMISSION)


func request_camera_permission() -> void:
	if OS.has_feature("android") and not has_camera_permission():
		OS.request_permission(CAMERA_PERMISSION)


func start(private_root: String = "", record_dir: String = "") -> bool:
	if _ov == null:
		return false
	if _started:
		return true
	if private_root.is_empty():
		private_root = external_files_dir()

	var ok: bool = _ov.start(private_root, record_dir)
	_started = ok
	return ok


func stop() -> void:
	if _ov != null and _started:
		_ov.stop()
	_started = false


func is_running() -> bool:
	if _ov == null:
		return false
	return bool(_ov.isRunning())


## 每帧调一次：把原生侧最新位姿通过 pose_changed 推出来
func poll() -> void:
	if _ov != null and _started:
		_ov.poll()


func get_pose() -> Array:
	if _ov == null or not _started:
		return []
	return _ov.getPose()


func get_trajectory() -> Array:
	if _ov == null or not _started:
		return []
	return _ov.getTrajectory()


func get_stats() -> String:
	if _ov == null:
		return "插件未加载"
	return str(_ov.getStats())


func get_last_error() -> String:
	if _ov == null:
		return ""
	return str(_ov.getLastError())


func set_recording(state: bool) -> void:
	if _ov != null:
		_ov.setRecording(state)


func _on_native_pose(dict: Dictionary) -> void:
	pose_count += 1
	pose_changed.emit(dict)


func _on_native_status(message: String) -> void:
	status_changed.emit(message)


## 已喂给 VIO 的相机帧数（用于判断 VIO 重启后帧是否恢复）
func frame_count() -> int:
	if _ov == null:
		return 0
	return int(_ov.getFrameCount())


## 已喂给 VIO 的 IMU 采样数
func imu_count() -> int:
	if _ov == null:
		return 0
	return int(_ov.getImuSampleCount())
