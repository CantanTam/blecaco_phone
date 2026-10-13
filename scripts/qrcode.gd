extends Control

signal qr_scanned(url: String)

@onready var camera: NativeCamera = $NativeCamera
@onready var preview: TextureRect = $CameraPreview

# 姿态检测相关节点
@onready var h_notice_bar = $ScanFrame/FrameBorder/HNoticeBar
@onready var v_notice_bar = $ScanFrame/FrameBorder/VNoticeBar
@onready var no_scan: Panel = $ScanFrame/NoScan

var camera_texture: ImageTexture
var zxing_helper

var scan_timer := 0.0
const SCAN_INTERVAL := 0.3

# 姿态检测阈值
const POSTURE_THRESHOLD := 0.966

var scanning := true
var qr_camera_stopped := false


func _ready() -> void:
	camera.camera_permission_granted.connect(
		_on_camera_permission_granted
	)
	camera.camera_permission_denied.connect(
		_on_camera_permission_denied
	)
	camera.frame_available.connect(
		_on_camera_frame
	)

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
	if qr_camera_stopped:
		return

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
	request.set_camera_id(
		selected_camera.get_camera_id()
	)
	request.set_width(1280)
	request.set_height(720)
	request.set_scale_width(640)
	request.set_scale_height(360)
	request.set_frames_to_skip(1)
	request.set_auto_upright(true)

	camera.start(request)

	print("[QRCode] QR camera started")


func _on_camera_permission_granted() -> void:
	_start_camera()


func _on_camera_permission_denied() -> void:
	push_error("Camera permission denied.")


func _on_camera_frame(frame: FrameInfo) -> void:
	var image := frame.get_image()

	if image == null:
		return

	if camera_texture == null:
		camera_texture = ImageTexture.create_from_image(
			image
		)
	else:
		camera_texture.update(image)

	preview.texture = camera_texture

	# 判断手机姿态是否符合扫描条件
	var posture_ok: bool = (
		h_notice_bar.cos_theta > POSTURE_THRESHOLD
		and v_notice_bar.cos_beta > POSTURE_THRESHOLD
	)

	# 姿态不符合时显示遮罩
	no_scan.visible = not posture_ok

	if zxing_helper == null:
		return

	if not scanning or not posture_ok:
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

		# 交由现有连接逻辑验证二维码。
		# 此处不立即停止相机，因为二维码可能无效。
		qr_scanned.emit(result)


func show_error() -> void:
	# 错误二维码：保持扫码摄像头运行，继续扫描。
	if qr_camera_stopped:
		print(
			"[QRCode] Camera already stopped; "
			+ "cannot resume scanning automatically"
		)
		return

	scanning = true
	print("[QRCode] Invalid QR, resume scanning")


func show_connecting() -> void:
	# 正确二维码：停止扫码。
	scanning = false

	if qr_camera_stopped:
		return

	# 先断开扫码回调，避免它接收后续光流摄像头帧。
	if camera.frame_available.is_connected(
		_on_camera_frame
	):
		camera.frame_available.disconnect(
			_on_camera_frame
		)

	# 停止原生摄像头会话，释放给光流摄像头使用。
	camera.stop()

	qr_camera_stopped = true

	print(
		"[QRCode] QR camera stopped; "
		+ "ready for OpticalFlowController"
	)
