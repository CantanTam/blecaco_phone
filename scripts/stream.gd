extends Control

signal connection_succeeded
signal connection_failed

const MAX_VIDEO_FPS := 60.0

@onready var video: TextureRect = $StreamWindow
@onready var connection: Node = get_node("../Connection")

var texture: ImageTexture
var latest_jpeg := PackedByteArray()

var decode_thread: Thread
var decode_mutex := Mutex.new()
var decode_semaphore := Semaphore.new()
var worker_running := false
var decode_busy := false

var decoded_image: Image
var decoded_ready := false

var video_timer := 0.0

var received_frames := 0
var decoded_frames := 0
var displayed_frames := 0


func _ready() -> void:
	connection.binary_message_received.connect(_on_binary_message_received)
	connection.connection_succeeded.connect(_on_connection_succeeded)
	connection.connection_failed.connect(_on_connection_failed)

	_start_decode_thread()


func _exit_tree() -> void:
	_stop_decode_thread()


func set_server_url(url: String) -> void:
	connection.set_server_url(url)


func _on_connection_succeeded() -> void:
	connection_succeeded.emit()


func _on_connection_failed() -> void:
	connection_failed.emit()


func _on_binary_message_received(data: PackedByteArray) -> void:
	if data.is_empty():
		return

	decode_mutex.lock()
	latest_jpeg = data
	decode_mutex.unlock()

	received_frames += 1


func _process(delta: float) -> void:
	_process_video(delta)


func _process_video(delta: float) -> void:
	video_timer += delta
	var interval := 1.0 / MAX_VIDEO_FPS

	if video_timer < interval:
		return

	video_timer -= interval

	var image_to_display: Image

	decode_mutex.lock()

	if decoded_ready:
		image_to_display = decoded_image
		decoded_image = null
		decoded_ready = false

	decode_mutex.unlock()

	if is_instance_valid(image_to_display) and not image_to_display.is_empty():
		if image_to_display != null and not image_to_display.is_empty():
			if texture == null or texture.get_width() != image_to_display.get_width() or texture.get_height() != image_to_display.get_height():
				texture = ImageTexture.create_from_image(image_to_display)
				video.texture = texture
			else:
				texture.update(image_to_display)

			displayed_frames += 1

	var should_decode := false

	decode_mutex.lock()

	if not decode_busy and not latest_jpeg.is_empty():
		decode_busy = true
		should_decode = true

	decode_mutex.unlock()

	if should_decode:
		decode_semaphore.post()


func _start_decode_thread() -> void:
	worker_running = true
	decode_thread = Thread.new()

	var error := decode_thread.start(_decode_worker)

	if error != OK:
		print("[Godot] Failed to start decode thread: ", error)
		worker_running = false
		decode_thread = null


func _decode_worker() -> void:
	while worker_running:
		decode_semaphore.wait()

		if not worker_running:
			break

		var jpeg_data: PackedByteArray

		decode_mutex.lock()
		jpeg_data = latest_jpeg
		latest_jpeg = PackedByteArray()
		decode_mutex.unlock()

		if jpeg_data.is_empty():
			decode_mutex.lock()
			decode_busy = false
			decode_mutex.unlock()
			continue

		var image := Image.new()
		var error := image.load_jpg_from_buffer(jpeg_data)

		decode_mutex.lock()

		if error == OK:
			decoded_image = image
			decoded_ready = true
			decoded_frames += 1

		decode_busy = false
		decode_mutex.unlock()

		if error != OK:
			print("[Godot] JPEG decode failed: ", error)


func _stop_decode_thread() -> void:
	if decode_thread == null:
		return

	decode_mutex.lock()
	worker_running = false
	decode_mutex.unlock()

	decode_semaphore.post()
	decode_thread.wait_to_finish()
	decode_thread = null
