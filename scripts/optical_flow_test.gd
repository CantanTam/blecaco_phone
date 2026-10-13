
extends Node

@onready var camera: NativeCamera = $NativeCamera

var frame_count: int = 0

var previous_buffer: PackedByteArray = PackedByteArray()
var last_match_count: int = 0
var last_radial_motion: float = 0.0

const BLOCK_RADIUS: int = 2
const SEARCH_RADIUS: int = 4
const GRID_STEP: int = 24


func _ready() -> void:
	camera.frame_width = 320
	camera.frame_height = 240
	camera.frames_to_skip = 0
	camera.is_grayscale = true
	camera.scale_width = 320
	camera.scale_height = 240
	camera.auto_upright = true

	camera.frame_available.connect(_on_frame_available)
	camera.camera_permission_granted.connect(_start_camera)
	camera.camera_permission_denied.connect(_on_camera_permission_denied)

	if camera.has_camera_permission():
		_start_camera()
	else:
		camera.request_camera_permission()


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
	frame_count += 1
	if frame_count % 30 == 0:
		print(
			"[OpticalFlow] Frame callback #",
			frame_count,
			" | Size=",
			info.get_width(),
			"x",
			info.get_height(),
			" | Grayscale=",
			info.is_grayscale()
		)

	var current_buffer: PackedByteArray = info.get_buffer()
	var width: int = info.get_width()
	var height: int = info.get_height()

	if not info.is_grayscale():
		return

	if current_buffer.size() != width * height:
		return

	if previous_buffer.is_empty():
		previous_buffer = current_buffer.duplicate()
		print("First grayscale frame stored: ", width, "x", height)
		return

	if frame_count % 2 == 0:
		var motion: Vector2 = _estimate_image_motion(
			previous_buffer,
			current_buffer,
			width,
			height
		)

		if frame_count % 30 == 0:
			var radial_label: String = "无明显径向趋势"

			if last_radial_motion > 1.0:
				radial_label = "画面扩张（疑似前进）"
			elif last_radial_motion < -1.0:
				radial_label = "画面收缩（疑似后退）"

			print(
				"X=", motion.x,
				" Y=", motion.y,
				" | Radial=", last_radial_motion,
				" | Trend=", radial_label,
				" | Matched blocks=", last_match_count
			)
			print(
				"Image motion (pixels/frame): X=",
				motion.x,
				" Y=",
				motion.y,
				" | Radial=",
				last_radial_motion,
				" | Matched blocks=",
				last_match_count
			)
			
		previous_buffer = current_buffer.duplicate()
	
	
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
