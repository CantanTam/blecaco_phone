extends Control

signal connection_succeeded
signal connection_failed

var server_url := ""
var waiting_for_initial_connection := false
var initial_connection_timer := 0.0
const INITIAL_CONNECTION_TIMEOUT := 2.0
const MAX_VIDEO_FPS := 60.0

@onready var video: TextureRect = $StreamWindow

var socket := WebSocketPeer.new()
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
var reconnect_timer := 0.0

var received_frames := 0
var decoded_frames := 0
var displayed_frames := 0


func _ready() -> void:
	_start_decode_thread()


func _exit_tree() -> void:
	_stop_decode_thread()


func _process(delta: float) -> void:
	socket.poll()
	
	if waiting_for_initial_connection:
		initial_connection_timer -= delta

		if initial_connection_timer <= 0.0:
			waiting_for_initial_connection = false
			socket.close()
			print("[Godot] Initial connection timeout")
			connection_failed.emit()
			return

	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			reconnect_timer = 0.0

			if waiting_for_initial_connection:
				waiting_for_initial_connection = false
				print("[Godot] Stream connection succeeded")
				connection_succeeded.emit()

			_receive_latest_packet()
			_process_video(delta)

		WebSocketPeer.STATE_CLOSED:
			if waiting_for_initial_connection:
				waiting_for_initial_connection = false
				print("[Godot] Stream connection failed")
				connection_failed.emit()
			else:
				_handle_closed(delta)


func set_server_url(url: String) -> void:
	server_url = url.replace("http://", "ws://").replace("https://", "wss://")

	if not server_url.ends_with("/"):
		server_url += "/"

	print("[Godot] Server URL: ", server_url)

	socket = WebSocketPeer.new()
	reconnect_timer = 0.0
	waiting_for_initial_connection = true
	initial_connection_timer = INITIAL_CONNECTION_TIMEOUT

	_connect_server()


func _connect_server() -> void:
	if server_url.is_empty():
		return

	print("[Godot] Connecting to: ", server_url)
	var error := socket.connect_to_url(server_url)
	if error != OK:
		print("[Godot] connect_to_url() failed: ", error)
		reconnect_timer = 3.0


func _receive_latest_packet() -> void:
	while socket.get_available_packet_count() > 0:
		var packet := socket.get_packet()
		if socket.was_string_packet():
			continue
		latest_jpeg = packet
		received_frames += 1


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

	if image_to_display != null:
		if texture == null:
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


func _handle_closed(delta: float) -> void:
	reconnect_timer += delta

	if reconnect_timer < 3.0:
		return

	reconnect_timer = 0.0
	socket = WebSocketPeer.new()
	_connect_server()
