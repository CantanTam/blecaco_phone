extends Control

signal qr_scanned(url: String)

@onready var camera: NativeCamera = $NativeCamera
@onready var preview: TextureRect = $CameraPreview
@onready var frame_border: Panel = $ScanFrame/FrameBorder
@onready var h_notice_bar: Panel = $ScanFrame/FrameBorder/HNoticeBar

var camera_texture: ImageTexture
var zxing_helper

var scan_timer := 0.0
const SCAN_INTERVAL := 0.3

var scanning := true

# 水平长条的固定厚度（像素）
const NOTICE_BAR_THICKNESS := 10.0
# 长条与扫描框底部的间距（像素）
const NOTICE_BAR_MARGIN := 10.0


func _ready() -> void:
	_configure_notice_bars()

	camera.camera_permission_granted.connect(_on_camera_permission_granted)
	camera.camera_permission_denied.connect(_on_camera_permission_denied)
	camera.frame_available.connect(_on_camera_frame)

	if OS.has_feature("android"):
		zxing_helper = JavaClassWrapper.wrap(
			"com.blecaco.zxing.ZxingHelper"
		)

		if zxing_helper:
			print("ZXing: ", zxing_helper.ping())
		else:
			push_error("Failed to load ZxingHelper.")
	else:
		print("Not running on Android.")

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
	request.set_width(1280)
	request.set_height(720)
	request.set_scale_width(640)
	request.set_scale_height(360)
	request.set_frames_to_skip(1)
	request.set_auto_upright(true)

	camera.start(request)


func _on_camera_permission_granted() -> void:
	_start_camera()


func _on_camera_permission_denied() -> void:
	push_error("Camera permission denied.")


func _on_camera_frame(frame: FrameInfo) -> void:
	var image := frame.get_image()

	if image == null:
		return

	if camera_texture == null:
		camera_texture = ImageTexture.create_from_image(image)
	else:
		camera_texture.update(image)

	preview.texture = camera_texture

	if zxing_helper == null:
		return

	if not scanning:
		return

	scan_timer -= get_process_delta_time()

	if scan_timer > 0.0:
		return

	scan_timer = SCAN_INTERVAL

	if image.get_format() != Image.FORMAT_RGBA8:
		image = image.duplicate()
		image.convert(Image.FORMAT_RGBA8)

	var data := image.get_data()

	var result: String = zxing_helper.scanQR(
		data,
		image.get_width(),
		image.get_height()
	)

	if result != "":
		scanning = false
		print("QR detected: ", result)
		qr_scanned.emit(result)


func show_error() -> void:
	scanning = true


func show_connecting() -> void:
	scanning = false


func _configure_notice_bars() -> void:
	# 长条以扫描框的水平中心为基准，锚点水平居中、垂直贴底。
	h_notice_bar.anchor_left = 0.5
	h_notice_bar.anchor_right = 0.5
	h_notice_bar.anchor_top = 1.0
	h_notice_bar.anchor_bottom = 1.0

	# 垂直方向：紧贴扫描框底部下方 NOTICE_BAR_MARGIN，
	# 厚度固定为 NOTICE_BAR_THICKNESS。
	h_notice_bar.offset_top = NOTICE_BAR_MARGIN
	h_notice_bar.offset_bottom = NOTICE_BAR_MARGIN + NOTICE_BAR_THICKNESS

	# 水平方向先给一个合理初值，_process 里每帧根据倾斜角刷新。
	h_notice_bar.offset_left = -frame_border.size.x / 2.0
	h_notice_bar.offset_right = frame_border.size.x / 2.0


func _process(_delta: float) -> void:
	# 屏幕坐标系下的重力向量，静止时长度约 9.8（单位 m/s²）。
	var gravity: Vector3 = Input.get_gravity()
	var gravity_length := gravity.length()

	# 默认满宽，等待有效的重力数据。
	var h_ratio := 1.0

	if gravity_length > 0.1:
		# Godot 返回的重力是"屏幕坐标系"下的，屏幕一旋转，
		# 坐标轴含义就变了：
		#   竖屏：屏幕 Y 轴 = 设备长轴
		#   横屏：屏幕 X 轴 = 设备长轴
		# 所以要根据屏幕方向选择正确的分量。
		var window_size := DisplayServer.window_get_size()
		var is_landscape := window_size.x > window_size.y

		var device_long_axis_g: float

		if is_landscape:
			device_long_axis_g = gravity.x
		else:
			device_long_axis_g = gravity.y

		# |长轴上的重力| / |重力| = cos(长轴与重力方向的夹角)
		#
		#   长轴水平 → 比值 ≈ 0 → 长度最长
		#   长轴竖直 → 比值 ≈ 1 → 长度最短
		#
		# 该比值只取决于"设备长轴与水平面的夹角"，
		# 与绕设备长轴的旋转无关，因此翻转手机不会影响长度。
		var ratio := clampf(
			absf(device_long_axis_g) / gravity_length,
			0.0,
			1.0
		)

		h_ratio = 1.0 - ratio

	# 以扫描框宽度作为最大长度。
	var h_length := frame_border.size.x * h_ratio

	# 左右两端对称地向中心收缩，保证长条始终以扫描框中心对称。
	h_notice_bar.offset_left = -h_length / 2.0
	h_notice_bar.offset_right = h_length / 2.0
