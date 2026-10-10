extends Control

signal qr_scanned(url: String)

@onready var camera: NativeCamera = $NativeCamera
@onready var preview: TextureRect = $CameraPreview

var camera_texture: ImageTexture
var zxing_helper

var scan_timer := 0.0
const SCAN_INTERVAL := 0.3

var scanning := true


func _ready() -> void:
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
