extends Node

@onready var camera: NativeCamera = $NativeCamera

# ============================================================
# 光流后台工作线程
# ============================================================

var _flow_thread: Thread = Thread.new()
var _flow_mutex: Mutex = Mutex.new()
var _flow_semaphore: Semaphore = Semaphore.new()

var _flow_thread_running: bool = false

# 最新待处理的摄像头帧
var _latest_frame: PackedByteArray = PackedByteArray()
var _latest_width: int = 0
var _latest_height: int = 0

# 是否已经通知工作线程有新帧
var _flow_wakeup_pending: bool = false

# 由工作线程维护的参考帧
var _worker_previous_buffer: PackedByteArray = PackedByteArray()
var _worker_previous_width: int = 0
var _worker_previous_height: int = 0

# 工作线程计算的最新结果
var _flow_result: Vector2 = Vector2.ZERO
var _flow_radial_result: float = 0.0
var _flow_match_result: int = 0
var _flow_result_ready: bool = false

# 光流平滑参数
const FLOW_SMOOTHING_ALPHA: float = 0.35

var _smoothed_motion: Vector2 = Vector2.ZERO
var _smoothed_radial_motion: float = 0.0
var _has_smoothed_motion: bool = false

var connection_node: Node = null

var frame_count: int = 0

var previous_buffer: PackedByteArray = PackedByteArray()
var last_match_count: int = 0
var last_radial_motion: float = 0.0

const BLOCK_RADIUS: int = 2
const SEARCH_RADIUS: int = 4
const GRID_STEP: int = 24


func _ready() -> void:
	# 查找现有的 Connection 节点
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	if connection_node == null:
		push_error(
			"[OpticalFlow] Connection 节点不存在"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
			"[OpticalFlow] Connection.send_action() 不存在"
		)
		connection_node = null

	# 配置 NativeCamera
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
	
	# 启动光流工作线程
	_flow_thread_running = true

	var thread_error: Error = _flow_thread.start(
		_flow_worker
	)

	if thread_error != OK:
		_flow_thread_running = false
		push_error(
			"[OpticalFlow] 无法启动后台线程"
		)
		return

	if camera.has_camera_permission():
		_start_camera()
	else:
		camera.request_camera_permission()


func _start_camera() -> void:
	var cameras := camera.get_all_cameras()

	if cameras.is_empty():
		push_error("[OpticalFlow] No camera found.")
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


func _on_camera_permission_denied() -> void:
	push_error("[OpticalFlow] Camera permission denied")


func _on_frame_available(info: FrameInfo) -> void:
	if not info.is_grayscale():
		return

	var current_buffer: PackedByteArray = info.get_buffer()
	var width: int = info.get_width()
	var height: int = info.get_height()

	if current_buffer.size() != width * height:
		return

	# 在主线程复制最新图像。
	# 后台线程不直接访问 NativeCamera。
	var frame_copy: PackedByteArray = current_buffer.duplicate()
	var should_wake_worker: bool = false

	_flow_mutex.lock()

	if not _flow_thread_running:
		_flow_mutex.unlock()
		return

	# 只保留最新图像，不积压旧帧。
	_latest_frame = frame_copy
	_latest_width = width
	_latest_height = height

	# 已经有唤醒信号时，不重复提交信号。
	if not _flow_wakeup_pending:
		_flow_wakeup_pending = true
		should_wake_worker = true

	_flow_mutex.unlock()

	if should_wake_worker:
		_flow_semaphore.post()
		
		
func _process(_delta: float) -> void:
	var has_result: bool = false
	var motion: Vector2 = Vector2.ZERO
	var radial: float = 0.0

	# 从后台线程取得最新光流结果
	_flow_mutex.lock()

	if _flow_result_ready:
		motion = _flow_result
		radial = _flow_radial_result
		_flow_result_ready = false
		has_result = true

	_flow_mutex.unlock()

	if not has_result:
		return

	# 第一次获取结果时直接采用，避免启动时缓慢爬升
	if not _has_smoothed_motion:
		_smoothed_motion = motion
		_smoothed_radial_motion = radial
		_has_smoothed_motion = true
	else:
		# 对图像水平、垂直运动量进行平滑
		_smoothed_motion = _smoothed_motion.lerp(
			motion,
			FLOW_SMOOTHING_ALPHA
		)

		# 对径向运动量进行平滑
		_smoothed_radial_motion = lerpf(
			_smoothed_radial_motion,
			radial,
			FLOW_SMOOTHING_ALPHA
		)

	# 仍然在主线程向 Blender 发送数据
	_send_translation(
		_smoothed_motion,
		_smoothed_radial_motion
	)
	

func _send_translation(motion: Vector2, radial: float) -> void:
	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	var translation_data: Dictionary = {
		"command": "translation",
		"x": motion.x,
		"y": motion.y,
		"radial": radial
	}

	connection_node.call(
		"send_action",
		"free",
		translation_data
	)


func _estimate_image_motion(
	previous: PackedByteArray,
	current: PackedByteArray,
	width: int,
	height: int
) -> Vector2:
	var dx_values: Array[int] = []
	var dy_values: Array[int] = []
	var radial_values: Array[float] = []

	var block_size: int = BLOCK_RADIUS * 2 + 1
	var block_area: int = block_size * block_size

	var center_x: float = width * 0.5
	var center_y: float = height * 0.5

	last_match_count = 0

	for y in range(
		BLOCK_RADIUS + SEARCH_RADIUS,
		height - BLOCK_RADIUS - SEARCH_RADIUS,
		GRID_STEP
	):
		for x in range(
			BLOCK_RADIUS + SEARCH_RADIUS,
			width - BLOCK_RADIUS - SEARCH_RADIUS,
			GRID_STEP
		):
			var min_pixel: int = 255
			var max_pixel: int = 0

			for py in range(-BLOCK_RADIUS, BLOCK_RADIUS + 1):
				for px in range(-BLOCK_RADIUS, BLOCK_RADIUS + 1):
					var pixel: int = int(
						previous[(y + py) * width + x + px]
					)

					if pixel < min_pixel:
						min_pixel = pixel

					if pixel > max_pixel:
						max_pixel = pixel

			# 跳过缺乏明显纹理的区块
			if max_pixel - min_pixel < 12:
				continue

			var best_cost: int = 1000000
			var best_dx: int = 0
			var best_dy: int = 0

			for dy in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
				for dx in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
					var cost: int = 0

					for py in range(-BLOCK_RADIUS, BLOCK_RADIUS + 1):
						for px in range(-BLOCK_RADIUS, BLOCK_RADIUS + 1):
							var previous_index: int = (
								(y + py) * width + x + px
							)

							var current_index: int = (
								(y + dy + py) * width + x + dx + px
							)

							cost += abs(
								int(previous[previous_index])
								- int(current[current_index])
							)

					if cost < best_cost:
						best_cost = cost
						best_dx = dx
						best_dy = dy

			if float(best_cost) / float(block_area) <= 45.0:
				dx_values.append(best_dx)
				dy_values.append(best_dy)

				# 计算区块相对于画面中心的径向运动
				var radial_x: float = float(x) - center_x
				var radial_y: float = float(y) - center_y

				var radial_length: float = Vector2(
					radial_x,
					radial_y
				).length()

				if radial_length > 20.0:
					var radial_motion: float = (
						float(best_dx) * radial_x
						+ float(best_dy) * radial_y
					) / radial_length

					radial_values.append(radial_motion)

	last_match_count = dx_values.size()

	if last_match_count < 8 or radial_values.size() < 8:
		last_radial_motion = 0.0
		return Vector2.ZERO

	# 使用径向运动中位数，降低异常区块的影响
	radial_values.sort()

	var radial_middle: int = int(radial_values.size() / 2)

	if radial_values.size() % 2 == 0:
		last_radial_motion = (
			radial_values[radial_middle - 1]
			+ radial_values[radial_middle]
		) / 2.0
	else:
		last_radial_motion = radial_values[radial_middle]

	return Vector2(
		_median(dx_values),
		_median(dy_values)
	)


func _median(values: Array[int]) -> float:
	values.sort()

	var middle: int = int(values.size() / 2)

	if values.size() % 2 == 0:
		return (
			float(values[middle - 1])
			+ float(values[middle])
		) / 2.0

	return float(values[middle])


# ============================================================
# 后台光流工作线程
# ============================================================

func _flow_worker() -> void:
	while true:
		# 等待主线程提交新帧
		_flow_semaphore.wait()

		var frame: PackedByteArray
		var width: int
		var height: int

		# 取得最新帧，然后释放锁，让主线程继续运行
		_flow_mutex.lock()

		if not _flow_thread_running:
			_flow_mutex.unlock()
			break

		frame = _latest_frame
		width = _latest_width
		height = _latest_height

		_flow_wakeup_pending = false

		_flow_mutex.unlock()

		if frame.is_empty() or width <= 0 or height <= 0:
			continue

		# 首帧或图像尺寸发生变化时，只更新参考帧
		if (
			_worker_previous_buffer.is_empty()
			or _worker_previous_width != width
			or _worker_previous_height != height
		):
			_worker_previous_buffer = frame
			_worker_previous_width = width
			_worker_previous_height = height
			continue

		# 在后台线程中进行光流计算
		var motion: Vector2 = _estimate_image_motion(
			_worker_previous_buffer,
			frame,
			width,
			height
		)

		# 保留本次计算的参考帧
		_worker_previous_buffer = frame
		_worker_previous_width = width
		_worker_previous_height = height

		# 将结果交给主线程
		_flow_mutex.lock()

		_flow_result = motion
		_flow_radial_result = last_radial_motion
		_flow_match_result = last_match_count
		_flow_result_ready = true

		_flow_mutex.unlock()


# ============================================================
# 安全退出后台线程
# ============================================================

func _exit_tree() -> void:
	_flow_mutex.lock()
	_flow_thread_running = false
	_flow_mutex.unlock()

	# 唤醒正在等待的线程，让它能够退出
	_flow_semaphore.post()

	if _flow_thread.is_started():
		_flow_thread.wait_to_finish()
