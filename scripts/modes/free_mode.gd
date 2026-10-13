extends Node

const ROTATION_SEND_INTERVAL: float = 1.0 / 100.0
const INITIALIZE_RETRY_INTERVAL: float = 0.25

# 打开后会以 ~100Hz 打印每条四元数，会冲掉日志缓冲区；排查时再改 true。
const VERBOSE_ORIENTATION_LOG := false

# ============================================================
# VIO（提供真实尺度的平移）
# ============================================================

const VIO_FRAME_WIDTH: int = 640
const VIO_FRAME_HEIGHT: int = 480

# ⚠️ 固定旋转，绝不能用 auto_upright：
# 否则相机坐标系会随手机姿态变化，相机↔IMU 外参不再恒定，VIO 会发散。
const VIO_FRAME_ROTATION: int = 90

# 调试：把喂给 VIO 的第一帧灰度图 dump 成 PNG（可用 adb 取回直接查看），
# 用来确认图像内容与朝向是否与标定假设一致。
const VIO_DUMP_FRAME := true
const VIO_DUMP_PATH: String = "user://vio_frame.png"

@onready var camera: NativeCamera = $NativeCamera
@onready var openvins: OpenVINS = $OpenVINS

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

# VIO 平移状态
var vio_last_position: Vector3 = Vector3.ZERO
var vio_has_last_position: bool = false
var vio_camera_started: bool = false

# 是否已经 dump 过首帧
var _vio_frame_dumped: bool = false


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

	_setup_vio()


func _exit_tree() -> void:
	if openvins != null:
		openvins.stop()

	if camera != null and vio_camera_started:
		camera.stop()


# ============================================================
# VIO 接线
# ============================================================

func _setup_vio() -> void:
	camera.frame_width = VIO_FRAME_WIDTH
	camera.frame_height = VIO_FRAME_HEIGHT
	camera.is_grayscale = true
	camera.scale_width = VIO_FRAME_WIDTH
	camera.scale_height = VIO_FRAME_HEIGHT
	camera.frames_to_skip = 0
	camera.auto_upright = false
	camera.frame_rotation = VIO_FRAME_ROTATION

	camera.frame_available.connect(_on_vio_frame)
	camera.camera_permission_granted.connect(_start_vio_camera)

	openvins.vio_initialized.connect(_on_vio_initialized)
	openvins.pose_updated.connect(_on_vio_pose)
	openvins.error_raised.connect(_on_vio_error)

	if camera.has_camera_permission():
		_start_vio_camera()
	else:
		camera.request_camera_permission()


## 相机帧入口：先做一次首帧 dump（调试），再交给 VIO。
func _on_vio_frame(a_info: FrameInfo) -> void:
	if VIO_DUMP_FRAME and not _vio_frame_dumped:
		_dump_vio_frame(a_info)

	openvins.feed_frame(a_info)


## 把首帧灰度图存成 PNG，并打印像素统计。
func _dump_vio_frame(a_info: FrameInfo) -> void:
	_vio_frame_dumped = true

	var width := a_info.get_width()
	var height := a_info.get_height()
	var buffer := a_info.get_buffer()

	if not a_info.is_grayscale() or buffer.size() != width * height:
		push_error("[VIO] dump: 帧格式异常")
		return

	var minimum := 255
	var maximum := 0
	var total: int = 0

	for value in buffer:
		minimum = mini(minimum, value)
		maximum = maxi(maximum, value)
		total += value

	var image := Image.create_from_data(
		width, height, false, Image.FORMAT_L8, buffer
	)

	var error := ERR_UNAVAILABLE

	if image != null:
		error = image.save_png(VIO_DUMP_PATH)

	print(
		"[VIO] dump: %dx%d rotation=%d min=%d max=%d mean=%.1f save=%d -> %s"
		% [
			width,
			height,
			a_info.get_rotation(),
			minimum,
			maximum,
			float(total) / float(buffer.size()),
			error,
			ProjectSettings.globalize_path(VIO_DUMP_PATH)
		]
	)


func _start_vio_camera() -> void:
	if vio_camera_started:
		return

	var cameras := camera.get_all_cameras()

	if cameras.is_empty():
		push_error("[VIO] No camera found.")
		return

	var selected_camera: CameraInfo = cameras[0]

	for cam in cameras:
		if not cam.is_front_facing():
			selected_camera = cam
			break

	var request := camera.create_feed_request()
	request.set_camera_id(selected_camera.get_camera_id())
	request.set_width(VIO_FRAME_WIDTH)
	request.set_height(VIO_FRAME_HEIGHT)
	request.set_scale_width(VIO_FRAME_WIDTH)
	request.set_scale_height(VIO_FRAME_HEIGHT)
	request.set_frames_to_skip(0)
	request.set_grayscale(true)
	request.set_auto_upright(false)
	request.set_rotation(VIO_FRAME_ROTATION)

	camera.start(request)
	vio_camera_started = true

	print("[VIO] 相机已启动 %dx%d rot=%d" % [
		VIO_FRAME_WIDTH, VIO_FRAME_HEIGHT, VIO_FRAME_ROTATION
	])

	openvins.start()


func _on_vio_error(a_message: String) -> void:
	push_error("[VIO] " + a_message)


func _on_vio_initialized() -> void:
	vio_has_last_position = false
	print("[VIO] 初始化完成")


func _on_vio_pose(a_pose: VioPose) -> void:
	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	var position := a_pose.get_position()

	if not vio_has_last_position:
		vio_last_position = position
		vio_has_last_position = true
		return

	var delta_world := position - vio_last_position
	vio_last_position = position

	if delta_world.length() < 1e-6:
		return

	# 转到手机当前机体坐标系（Android 传感器系 X右/Y上/Z朝屏幕外），
	# 与 getrotation.gd 使用同一坐标系，轴映射交给 Blender 端。
	var delta_body: Vector3 = (
		a_pose.get_orientation().inverse() * delta_world
	)

	connection_node.call("send_action", "free", {
		"command": "translation",
		"x": delta_body.x,
		"y": delta_body.y,
		"z": delta_body.z
	})


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

	if rotation_send_timer < ROTATION_SEND_INTERVAL:
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

	var sent: bool = bool(
		connection_node.call(
			"send_action",
			"free",
			quaternion_data
		)
	)

	if VERBOSE_ORIENTATION_LOG:
		print(
			"[Orientation] Quaternion sent: ",
			"X=", snappedf(q.x, 0.01),
			" Y=", snappedf(q.y, 0.01),
			" Z=", snappedf(q.z, 0.01),
			" W=", snappedf(q.w, 0.01)
		)
