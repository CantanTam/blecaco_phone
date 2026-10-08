extends Control

@onready var qr_code = $QRCode
@onready var stream = $Stream


func _ready() -> void:
	qr_code.qr_scanned.connect(_on_qr_scanned)
	stream.connection_succeeded.connect(_on_stream_connection_succeeded)
	stream.connection_failed.connect(_on_stream_connection_failed)

	stream.visible = false


func _on_qr_scanned(url: String) -> void:
	print("[Main] QR scanned: ", url)

	qr_code.show_connecting()
	stream.set_server_url(url)


func _on_stream_connection_succeeded() -> void:
	print("[Main] Stream connection succeeded")

	qr_code.visible = false
	stream.visible = true


func _on_stream_connection_failed() -> void:
	print("[Main] Stream connection failed")

	qr_code.visible = true
	stream.visible = false
	qr_code.show_error()
