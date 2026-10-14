extends Node

# ============================================================
# 光流调试场景
# ============================================================
# 本场景不再自带一份算法副本，而是直接复用
# scripts/modes/optical_flow_controller.gd 里的实现，
# 只负责把估算结果和耗时打印出来，方便真机调参。
#
# 注意：这里是在主线程直接调用的，会阻塞渲染线程，
# 所以帧率看起来会很低——这是刻意为之，只为看数据。
# ============================================================

const ControllerScript := preload(
	"res://scripts/modes/optical_flow_controller.gd"
)

@onready var camera: NativeCamera = $NativeCamera

const LOG_INTERVAL: int = 15

var _estimator: Node = null
var _previous_buffer: PackedByteArray = PackedByteArray()
var _frame_count: int = 0
var _measured_frames: int = 0
var _total_estimate_usec: int = 0


func _ready() -> void:
	# 只借用算法函数，不进入场景树，因此不会启动后台线程
	_estimator = ControllerScript.new()

	camera.frame_width = 320
	camera.frame_height = 240
	camera.frames_to_skip = 0
	camera.is_grayscale = true
	camera.scale_width = 320
	camera.scale_height = 240
	camera.auto_upright = true

	camera.frame_available.connect(_on_frame_available)
	camera.camera_permission_granted.connect(_start_camera)
	camera.camera_permission_denied.connect(
		_on_camera_permission_denied
	)

	if camera.has_camera_permission():
		_start_camera()
	else:
		camera.request_camera_permission()


func _exit_tree() -> void:
	if _estimator != null:
		_estimator.free()
		_estimator = null


func _start_camera() -> void:
	var cameras := camera.get_all_cameras()

	if cameras.is_empty():
		push_error("No camera found.")
		return

	var selected_camera: CameraInfo = cameras[0]

	for cam in cameras:
		if not cam.is_front_facing():
			selected_camera = cam
			break

	var request := camera.create_feed_request()
	request.set_camera_id(selected_camera.get_camera_id())
	request.set_width(640)
	request.set_height(480)
	request.set_scale_width(320)
	request.set_scale_height(240)
	request.set_frames_to_skip(0)
	request.set_grayscale(true)
	request.set_auto_upright(true)

	camera.start(request)
	print("Native Camera started: ", selected_camera.get_camera_id())


func _on_camera_permission_denied() -> void:
	push_error("Camera permission denied")


func _on_frame_available(info: FrameInfo) -> void:
	if not info.is_grayscale():
		return

	var current_buffer: PackedByteArray = info.get_buffer()
	var width: int = info.get_width()
	var height: int = info.get_height()

	if current_buffer.size() != width * height:
		return

	_frame_count += 1

	if _previous_buffer.is_empty():
		_previous_buffer = current_buffer.duplicate()
		print("First grayscale frame stored: ", width, "x", height)
		return

	var start := Time.get_ticks_usec()
	var result: Dictionary = _estimator._estimate_motion(
		_previous_buffer,
		current_buffer,
		width,
		height,
		true
	)
	_total_estimate_usec += Time.get_ticks_usec() - start
	_measured_frames += 1

	_previous_buffer = current_buffer.duplicate()

	if _frame_count % LOG_INTERVAL != 0:
		return

	var motion := Vector2(result["motion"])
	var radial := float(result["radial"])

	var label: String = "无明显径向趋势"

	if radial > 1.0:
		label = "画面扩张（疑似前进）"
	elif radial < -1.0:
		label = "画面收缩（疑似后退）"

	print(
		"X=", snappedf(motion.x, 0.01),
		" Y=", snappedf(motion.y, 0.01),
		" | Radial=", snappedf(radial, 0.01),
		" | Trend=", label,
		" | Inliers=", result["inliers"],
		"/", result["features"],
		" | FBreject=", result["fb_rejected"],
		" | Roll=", snappedf(float(result["rotation"]), 0.0001),
		" | Expand=", snappedf(float(result["expansion"]), 0.0001),
		" | RMS=", snappedf(float(result["rms"]), 0.01),
		" | valid=", result["valid"],
		" | est=", snappedf(
			float(_total_estimate_usec)
			/ 1000.0
			/ float(maxi(_measured_frames, 1)),
			0.01
		),
		" ms"
	)
