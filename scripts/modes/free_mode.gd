
extends Node

const ROTATION_SEND_INTERVAL: float = 1.0

var rotation_sender = preload(
	"res://scripts/getrotation.gd"
).new()

var rotation_send_timer: float = 0.0


func _ready() -> void:
	if rotation_sender.is_available():
		print("[Orientation] Plugin loaded")
	else:
		push_error(
			"[Orientation] Plugin singleton not found"
		)


func _process(delta: float) -> void:
	if not rotation_sender.has_orientation_data():
		return

	rotation_send_timer += delta

	if rotation_send_timer < ROTATION_SEND_INTERVAL:
		return

	rotation_send_timer = 0.0

	# 直接读取当前姿态，不在进入 Free Mode 时自动校准
	var q: Quaternion = (
		rotation_sender.get_rotation_quaternion()
	)

	print(
		"[Orientation] Blender-aligned quaternion: ",
		"X=", snappedf(q.x, 0.01),
		" Y=", snappedf(q.y, 0.01),
		" Z=", snappedf(q.z, 0.01),
		" W=", snappedf(q.w, 0.01)
	)
